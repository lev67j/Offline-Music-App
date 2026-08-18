from __future__ import annotations

from html import escape
import secrets
import uuid

from fastapi import APIRouter, Depends, Form, HTTPException, Query
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .auth import (
    ALL_SCOPES,
    READ_SCOPE,
    authorize,
    create_link_code,
    current_device,
    exchange_code,
    hash_secret,
    public_base_url,
    redirect_with,
    refresh_access,
    resource_url,
)
from .database import get_session
from .library import load_library, merge_library
from .models import Connection, Device

router = APIRouter()


class SyncPayload(BaseModel):
    tracks: list[dict] = []
    albums: list[dict] = []
    track_tombstones: list[dict] = []
    album_tombstones: list[dict] = []


@router.post("/api/v1/device/register")
async def register_device(session: AsyncSession = Depends(get_session)) -> dict:
    raw_secret = secrets.token_urlsafe(32)
    device = Device(secret_hash=hash_secret(raw_secret))
    session.add(device)
    await session.commit()
    return {"device_id": str(device.id), "device_token": f"{device.id}.{raw_secret}"}


@router.post("/api/v1/library/sync")
async def sync_library(
    payload: SyncPayload,
    device: Device = Depends(current_device),
    session: AsyncSession = Depends(get_session),
) -> dict:
    library = merge_library(device, payload.model_dump())
    await session.commit()
    return {**library, "revision": device.revision}


@router.get("/api/v1/library")
async def get_library(device: Device = Depends(current_device)) -> dict:
    return {**load_library(device), "revision": device.revision}


@router.post("/api/v1/mcp/link_codes")
async def new_link_code(
    device: Device = Depends(current_device),
    session: AsyncSession = Depends(get_session),
) -> dict:
    code, expires_at = await create_link_code(session, device)
    return {"code": code, "expires_at": expires_at, "scopes": ALL_SCOPES}


@router.get("/api/v1/mcp/connections")
async def list_connections(
    device: Device = Depends(current_device),
    session: AsyncSession = Depends(get_session),
) -> list[dict]:
    result = await session.execute(
        select(Connection).where(Connection.device_id == device.id).order_by(Connection.created_at.desc())
    )
    return [
        {
            "id": str(item.id),
            "client_id": item.client_id,
            "scopes": item.scopes.split(),
            "created_at": item.created_at,
            "last_used_at": item.last_used_at,
            "revoked_at": item.revoked_at,
        }
        for item in result.scalars()
    ]


@router.delete("/api/v1/mcp/connections/{connection_id}")
async def revoke_connection(
    connection_id: uuid.UUID,
    device: Device = Depends(current_device),
    session: AsyncSession = Depends(get_session),
) -> dict:
    connection = await session.scalar(select(Connection).where(
        Connection.id == connection_id, Connection.device_id == device.id
    ))
    if not connection:
        raise HTTPException(404, "Connection not found")
    from .auth import now_utc
    connection.revoked_at = now_utc()
    await session.commit()
    return {"id": str(connection.id), "revoked": True}


@router.get("/.well-known/oauth-protected-resource")
@router.get("/.well-known/oauth-protected-resource/mcp")
async def protected_resource_metadata() -> dict:
    return {
        "resource": resource_url(),
        "authorization_servers": [public_base_url()],
        "scopes_supported": ALL_SCOPES,
        "bearer_methods_supported": ["header"],
    }


@router.get("/.well-known/oauth-authorization-server")
async def authorization_server_metadata() -> dict:
    base = public_base_url()
    return {
        "issuer": base,
        "authorization_endpoint": f"{base}/oauth/authorize",
        "token_endpoint": f"{base}/oauth/token",
        "client_id_metadata_document_supported": True,
        "token_endpoint_auth_methods_supported": ["none"],
        "code_challenge_methods_supported": ["S256"],
        "scopes_supported": ALL_SCOPES,
        "response_types_supported": ["code"],
        "grant_types_supported": ["authorization_code", "refresh_token"],
    }


@router.get("/oauth/authorize", response_class=HTMLResponse)
async def authorize_form(
    response_type: str = Query("code"),
    client_id: str = Query(""),
    redirect_uri: str = Query(""),
    scope: str = Query(" ".join(ALL_SCOPES)),
    state: str = Query(""),
    code_challenge: str = Query(""),
    code_challenge_method: str = Query("S256"),
    resource: str = Query(""),
) -> HTMLResponse:
    if response_type != "code" or code_challenge_method != "S256" or not code_challenge:
        raise HTTPException(400, "OAuth code flow with PKCE S256 is required")
    from .auth import validate_redirect
    validate_redirect(redirect_uri)
    fields = {
        "response_type": response_type,
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "scope": scope,
        "state": state,
        "code_challenge": code_challenge,
        "code_challenge_method": code_challenge_method,
        "resource": resource,
    }
    hidden = "".join(
        f'<input type="hidden" name="{escape(key)}" value="{escape(value, quote=True)}">'
        for key, value in fields.items()
    )
    return HTMLResponse(f"""
    <!doctype html><html lang="ru"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Подключить Offline Music</title><style>
    body{{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#101010;color:#fff;margin:0;padding:32px}}
    main{{max-width:480px;margin:10vh auto;background:#1c1c1e;border-radius:24px;padding:28px}}
    input,button{{box-sizing:border-box;width:100%;font-size:20px;padding:14px;border-radius:12px}}
    input{{background:#2c2c2e;color:#fff;border:1px solid #444;margin:12px 0 16px;text-align:center;letter-spacing:8px}}
    button{{background:#1ed760;color:#000;border:0;font-weight:700}} p{{color:#aaa;line-height:1.45}}
    </style></head><body><main><h1>Offline Music + ChatGPT</h1>
    <p>Открой настройки Offline Music, нажми «Сгенерировать код» и введи шестизначный код ниже.</p>
    <form method="post" action="{escape(public_base_url(), quote=True)}/oauth/authorize">{hidden}
    <input name="link_code" inputmode="numeric" autocomplete="one-time-code" maxlength="6" required>
    <button type="submit">Подключить</button></form></main></body></html>
    """)


@router.post("/oauth/authorize")
async def authorize_submit(
    client_id: str = Form(...), redirect_uri: str = Form(...), scope: str = Form(" ".join(ALL_SCOPES)),
    state: str = Form(""), code_challenge: str = Form(...), resource: str = Form(""),
    link_code: str = Form(...), session: AsyncSession = Depends(get_session),
) -> RedirectResponse:
    try:
        raw_code = await authorize(
            session, client_id=client_id, redirect_uri=redirect_uri, requested_scopes=scope,
            challenge=code_challenge, resource=resource or None, link_code=link_code,
        )
        params = {"code": raw_code}
        if state:
            params["state"] = state
    except HTTPException as exc:
        params = {"error": "access_denied", "error_description": str(exc.detail)}
        if state:
            params["state"] = state
    return RedirectResponse(redirect_with(redirect_uri, params), status_code=302)


@router.post("/oauth/token")
async def token_endpoint(
    grant_type: str = Form(...), client_id: str = Form(...), code: str | None = Form(None),
    redirect_uri: str | None = Form(None), code_verifier: str | None = Form(None),
    refresh_token: str | None = Form(None), resource: str | None = Form(None),
    session: AsyncSession = Depends(get_session),
) -> JSONResponse:
    if grant_type == "authorization_code" and code and redirect_uri and code_verifier:
        grant = await exchange_code(
            session, code=code, client_id=client_id, redirect_uri=redirect_uri,
            verifier=code_verifier, resource=resource,
        )
    elif grant_type == "refresh_token" and refresh_token:
        grant = await refresh_access(session, raw_token=refresh_token, client_id=client_id, resource=resource)
    else:
        raise HTTPException(400, "invalid_request")
    return JSONResponse({
        "access_token": grant.access_token,
        "refresh_token": grant.refresh_token,
        "token_type": "Bearer",
        "expires_in": 3600,
        "scope": grant.scopes,
    }, headers={"Cache-Control": "no-store", "Pragma": "no-cache"})
