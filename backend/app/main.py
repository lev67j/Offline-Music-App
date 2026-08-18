from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .api import router
from .database import Base, engine
from .mcp_server import offline_music_mcp


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    async with offline_music_mcp.session_manager.run():
        yield


async def init_db() -> None:
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)


app = FastAPI(title="Offline Music MCP", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["https://chatgpt.com", "https://chat.openai.com"],
    allow_methods=["*"], allow_headers=["*"], expose_headers=["Mcp-Session-Id"],
)
app.include_router(router)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "service": "offline-music-mcp"}


app.mount("/", offline_music_mcp.streamable_http_app())
