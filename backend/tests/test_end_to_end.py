from __future__ import annotations

import base64
import hashlib
from urllib.parse import parse_qs, urlparse

from fastapi.testclient import TestClient

from app.main import app


def challenge(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode()).digest()
    return base64.urlsafe_b64encode(digest).decode().rstrip("=")


def test_device_sync_oauth_and_mcp_tools() -> None:
    with TestClient(app, base_url="http://testserver") as client:
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

        link = client.post("/api/v1/mcp/link_codes", headers=headers)
        assert link.status_code == 200
        assert len(link.json()["code"]) == 6

        verifier = "offline-music-test-verifier-with-enough-entropy"
        authorization = client.post(
            "/oauth/authorize",
            data={
                "response_type": "code",
                "client_id": "https://chatgpt.com/oauth/test-client.json",
                "redirect_uri": "http://test/callback",
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
                "redirect_uri": "http://test/callback",
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

