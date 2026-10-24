from __future__ import annotations

import base64
import asyncio
import hashlib
import os
import uuid
from urllib.parse import parse_qs, urlparse

from fastapi.testclient import TestClient

os.environ.setdefault("OFFLINE_MUSIC_JWT_SECRET", "offline-music-test-secret")
os.environ.setdefault("OFFLINE_MUSIC_PUBLIC_BASE_URL", "http://testserver")

from app.main import app
from app.database import SessionLocal
from app.models import DeviceLibraryBackup


def challenge(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode()).digest()
    return base64.urlsafe_b64encode(digest).decode().rstrip("=")


def test_device_sync_oauth_and_mcp_tools() -> None:
    with TestClient(app, base_url="http://testserver") as client:
        chatgpt_redirect = "https://chatgpt.com/connector/oauth/offline-music-test-callback"
        registration = client.post("/api/v1/device/register")
        assert registration.status_code == 200
        headers = {"Authorization": f"Bearer {registration.json()['device_token']}"}

        synced = client.post(
            "/api/v1/library/sync",
            headers=headers,
            json={
                "tracks": [],
                "albums": [{
                    "id": "10000000-0000-0000-0000-000000000001",
                    "name": "Offline Music",
                    "track_ids": [],
                    "updated_at": "2026-08-19T00:00:00Z",
                }],
                "track_tombstones": [],
                "album_tombstones": [],
            },
        )
        assert synced.status_code == 200
        assert synced.json()["albums"][0]["name"] == "Offline Music"

        device_id = uuid.UUID(registration.json()["device_token"].split(".", 1)[0])

        async def backup_count() -> int:
            from sqlalchemy import func, select
            async with SessionLocal() as session:
                return int(await session.scalar(
                    select(func.count()).select_from(DeviceLibraryBackup).where(
                        DeviceLibraryBackup.device_id == device_id
                    )
                ) or 0)

        assert asyncio.run(backup_count()) == 1

        link = client.post("/api/v1/mcp/link_codes", headers=headers)
        assert link.status_code == 200
        assert len(link.json()["code"]) == 6

        verifier = "offline-music-test-verifier-with-enough-entropy"
        authorization = client.post(
            "/oauth/authorize",
            data={
                "response_type": "code",
                "client_id": "https://chatgpt.com/oauth/test-client.json",
                "redirect_uri": chatgpt_redirect,
                "scope": "offline_music.read offline_music.write offline_music.delete_track",
                "state": "test-state",
                "code_challenge": challenge(verifier),
                "code_challenge_method": "S256",
                "resource": "http://testserver/mcp",
                "link_code": link.json()["code"],
            },
            follow_redirects=False,
        )
        assert authorization.status_code == 302
        code = parse_qs(urlparse(authorization.headers["location"]).query)["code"][0]

        token = client.post(
            "/oauth/token",
            data={
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": chatgpt_redirect,
                "client_id": "https://chatgpt.com/oauth/test-client.json",
                "code_verifier": verifier,
                "resource": "http://testserver/mcp",
            },
        )
        assert token.status_code == 200
        access_token = token.json()["access_token"]

        mcp_headers = {
            "Authorization": f"Bearer {access_token}",
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
        }
        initialized = client.post(
            "/mcp",
            headers=mcp_headers,
            json={
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "test", "version": "1"},
                },
            },
        )
        assert initialized.status_code == 200

        tools = client.post(
            "/mcp",
            headers=mcp_headers,
            json={"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
        )
        assert tools.status_code == 200
        names = {item["name"] for item in tools.json()["result"]["tools"]}
        assert "create_album" in names
        assert "delete_track" in names
        assert "set_track_lyrics" in names
        assert "delete_album" not in names
        assert {"tag_tracks", "set_track_tags", "list_tags", "remove_track_from_album"} <= names

        def call(request_id: int, name: str, arguments: dict) -> dict:
            response = client.post("/mcp", headers=mcp_headers, json={
                "jsonrpc": "2.0", "id": request_id, "method": "tools/call",
                "params": {"name": name, "arguments": arguments},
            })
            assert response.status_code == 200, response.text
            result = response.json()["result"]
            assert not result.get("isError"), result
            import json
            return result.get("structuredContent") or json.loads(result["content"][0]["text"])

        album_id = "10000000-0000-0000-0000-000000000001"
        first = call(10, "add_track", {"title": "Run", "artist": "A", "album_id": album_id})
        second = call(11, "add_track", {"title": "Sleep", "artist": "B", "album_id": album_id})
        tagged = call(12, "tag_tracks", {"track_ids": [first["id"], second["id"]], "add": ["#Gym", "night"]})
        assert tagged["changed_count"] == 2
        call(13, "tag_tracks", {"track_ids": [second["id"]], "add": ["Calm"], "remove": ["GYM"]})
        tags = {item["tag"]: item["track_count"] for item in call(14, "list_tags", {"album_id": album_id})["tags"]}
        assert tags == {"Gym": 1, "night": 2, "Calm": 1}
        gym = call(15, "list_tracks", {"tag": "gym"})["tracks"]
        assert [item["title"] for item in gym] == ["Run"]
        assert call(16, "set_track_tags", {"track_id": first["id"], "tags": []})["tags"] is None

        removed = call(17, "remove_track_from_album", {"track_id": first["id"], "album_id": album_id})
        assert removed["track_ids"] == [second["id"]]
        library = client.get("/api/v1/library", headers=headers).json()
        assert first["id"] in {item["id"] for item in library["tracks"]}
        assert library["tracks"][-1]["tags"] == ["night", "Calm"]

        registered = client.post("/oauth/register", json={
            "client_name": "Claude Code", "redirect_uris": ["http://localhost:53682/callback"],
        })
        assert registered.status_code == 201
        assert registered.json()["client_id"].startswith("mcp-client-")
        assert client.post("/oauth/register", json={"redirect_uris": ["https://evil.example/cb"]}).status_code == 400
        assert client.get("/.well-known/oauth-authorization-server").json()["registration_endpoint"].endswith("/oauth/register")

        response = client.get(
            "/oauth/authorize",
            params={
                "redirect_uri": "https://example.com/callback",
                "code_challenge": "challenge",
                "code_challenge_method": "S256",
            },
        )
        assert response.status_code == 400
        assert response.json()["detail"] == "Unsupported redirect_uri"
