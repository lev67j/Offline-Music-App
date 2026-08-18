from __future__ import annotations

import base64
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import hashlib
import os
import secrets
import uuid
from urllib.parse import urlencode

from fastapi import Depends, Header, HTTPException
from jose import JWTError, jwt
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .database import get_session
from .models import AuthorizationCode, Connection, Device, LinkCode

READ_SCOPE = "offline_music.read"
WRITE_SCOPE = "offline_music.write"
DELETE_SCOPE = "offline_music.delete_track"
ALL_SCOPES = [READ_SCOPE, WRITE_SCOPE, DELETE_SCOPE]
ALGORITHM = "HS256"


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def public_base_url() -> str:
    return os.getenv("OFFLINE_MUSIC_PUBLIC_BASE_URL", os.getenv("PUBLIC_BASE_URL", "http://localhost:8000")).rstrip("/")


def resource_url() -> str:
    return f"{public_base_url()}/mcp"


def hash_secret(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def split_scopes(value: str | None) -> list[str]:
    values = (value or READ_SCOPE).split()
    return [scope for scope in ALL_SCOPES if scope in values] or [READ_SCOPE]


def code_challenge(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).decode().rstrip("=")


def _jwt_secret() -> str:
    secret = os.getenv("OFFLINE_MUSIC_JWT_SECRET", os.getenv("JWT_SECRET"))
    if not secret:
        raise RuntimeError("JWT_SECRET must be configured")
    return secret


async def current_device(
    authorization: str | None = Header(None),
    session: AsyncSession = Depends(get_session),
) -> Device:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "Device authorization required")
    token = authorization[7:]
    try:
        device_id, secret = token.split(".", 1)
        owner = await session.get(Device, uuid.UUID(device_id))
    except (ValueError, AttributeError):
        owner = None
        secret = ""
    if not owner or not secrets.compare_digest(owner.secret_hash, hash_secret(secret)):
        raise HTTPException(401, "Invalid device authorization")
    return owner


async def create_link_code(session: AsyncSession, device: Device) -> tuple[str, datetime]:
    raw = f"{secrets.randbelow(1_000_000):06d}"
    expires = now_utc() + timedelta(minutes=10)
    session.add(LinkCode(device_id=device.id, code_hash=hash_secret(raw), expires_at=expires))
    await session.commit()
    return raw, expires


def validate_redirect(uri: str) -> None:
    allowed = (
        "https://chatgpt.com/connector_platform_oauth_redirect",
        "https://chat.openai.com/aip/plugin-",
        "http://localhost:",
        "http://127.0.0.1:",
        "http://test/",
    )
    if not any(uri.startswith(prefix) for prefix in allowed):
        raise HTTPException(400, "Unsupported redirect_uri")


async def authorize(
    session: AsyncSession,
    *,
    client_id: str,
    redirect_uri: str,
    requested_scopes: str,
    challenge: str,
    resource: str | None,
    link_code: str,
) -> str:
    validate_redirect(redirect_uri)
    if resource and resource.rstrip("/") != resource_url():
        raise HTTPException(400, "Unsupported resource")
    link = await session.scalar(select(LinkCode).where(LinkCode.code_hash == hash_secret(link_code.strip())))
    expires = link.expires_at if link and link.expires_at.tzinfo else (link.expires_at.replace(tzinfo=timezone.utc) if link else None)
    if not link or link.consumed_at or not expires or expires < now_utc():
        raise HTTPException(400, "Invalid or expired link code")
    link.consumed_at = now_utc()
    scopes = " ".join(split_scopes(requested_scopes))
    connection = Connection(
        device_id=link.device_id,
        client_id=client_id,
        scopes=scopes,
        resource=resource_url(),
    )
    session.add(connection)
    await session.flush()
    raw_code = secrets.token_urlsafe(32)
    session.add(AuthorizationCode(
        device_id=link.device_id,
        connection_id=connection.id,
        code_hash=hash_secret(raw_code),
        client_id=client_id,
        redirect_uri=redirect_uri,
        scopes=scopes,
        resource=resource_url(),
        code_challenge=challenge,
        expires_at=now_utc() + timedelta(minutes=5),
    ))
    await session.commit()
    return raw_code


@dataclass
class TokenGrant:
    access_token: str
    refresh_token: str
    scopes: str


def create_access_token(connection: Connection) -> str:
    expires = now_utc() + timedelta(minutes=60)
    return jwt.encode({
        "sub": str(connection.device_id),
        "connection_id": str(connection.id),
        "client_id": connection.client_id,
        "scope": connection.scopes,
        "iss": public_base_url(),
        "aud": resource_url(),
        "exp": expires,
    }, _jwt_secret(), algorithm=ALGORITHM)


def decode_access_token(token: str) -> dict:
    return jwt.decode(token, _jwt_secret(), algorithms=[ALGORITHM], audience=resource_url(), issuer=public_base_url())


async def exchange_code(
    session: AsyncSession, *, code: str, client_id: str, redirect_uri: str, verifier: str, resource: str | None
) -> TokenGrant:
    auth_code = await session.scalar(select(AuthorizationCode).where(AuthorizationCode.code_hash == hash_secret(code)))
    expires = auth_code.expires_at if auth_code and auth_code.expires_at.tzinfo else (auth_code.expires_at.replace(tzinfo=timezone.utc) if auth_code else None)
    if not auth_code or auth_code.consumed_at or not expires or expires < now_utc():
        raise HTTPException(400, "Invalid authorization code")
    if auth_code.client_id != client_id or auth_code.redirect_uri != redirect_uri:
        raise HTTPException(400, "Authorization request mismatch")
    if resource and resource.rstrip("/") != auth_code.resource.rstrip("/"):
        raise HTTPException(400, "Resource mismatch")
    if code_challenge(verifier) != auth_code.code_challenge:
        raise HTTPException(400, "Invalid PKCE verifier")
    connection = await session.get(Connection, auth_code.connection_id)
    if not connection or connection.revoked_at:
        raise HTTPException(400, "Connection revoked")
    raw_refresh = secrets.token_urlsafe(48)
    connection.refresh_token_hash = hash_secret(raw_refresh)
    connection.last_used_at = now_utc()
    auth_code.consumed_at = now_utc()
    await session.commit()
    return TokenGrant(create_access_token(connection), raw_refresh, connection.scopes)


async def refresh_access(session: AsyncSession, *, raw_token: str, client_id: str, resource: str | None) -> TokenGrant:
    connection = await session.scalar(select(Connection).where(Connection.refresh_token_hash == hash_secret(raw_token)))
    if not connection or connection.revoked_at or connection.client_id != client_id:
        raise HTTPException(400, "Invalid refresh token")
    if resource and resource.rstrip("/") != connection.resource.rstrip("/"):
        raise HTTPException(400, "Resource mismatch")
    connection.last_used_at = now_utc()
    await session.commit()
    return TokenGrant(create_access_token(connection), raw_token, connection.scopes)


def redirect_with(uri: str, params: dict[str, str]) -> str:
    return f"{uri}{'&' if '?' in uri else '?'}{urlencode(params)}"
