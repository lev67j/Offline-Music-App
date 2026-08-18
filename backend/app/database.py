from __future__ import annotations

import os
import ssl
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from collections.abc import AsyncIterator

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase


def _database_url() -> str:
    raw = os.getenv("OFFLINE_MUSIC_DATABASE_URL", "sqlite+aiosqlite:///./offline_music.db")
    if raw.startswith("sqlite"):
        return raw
    parts = urlsplit(raw)
    scheme = "postgresql+asyncpg" if parts.scheme in {"postgres", "postgresql", "postgresql+asyncpg"} else parts.scheme
    query = [(key, value) for key, value in parse_qsl(parts.query) if key.lower() not in {"sslmode", "channel_binding"}]
    return urlunsplit((scheme, parts.netloc, parts.path, urlencode(query), parts.fragment))


class Base(DeclarativeBase):
    pass


DATABASE_URL = _database_url()
engine = create_async_engine(
    DATABASE_URL,
    pool_pre_ping=True,
    connect_args={"ssl": ssl.create_default_context()} if DATABASE_URL.startswith("postgresql+asyncpg://") else {},
)
SessionLocal = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


async def get_session() -> AsyncIterator[AsyncSession]:
    async with SessionLocal() as session:
        yield session
