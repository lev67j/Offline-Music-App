from __future__ import annotations

import uuid
from typing import Any
from urllib.parse import urlparse

from fastapi import HTTPException
from mcp.server.auth.middleware.auth_context import get_access_token
from mcp.server.auth.provider import AccessToken, TokenVerifier
from mcp.server.auth.settings import AuthSettings
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import ToolAnnotations
from sqlalchemy import select

from .auth import ALL_SCOPES, DELETE_SCOPE, READ_SCOPE, WRITE_SCOPE, decode_access_token, now_utc, public_base_url, resource_url
from .database import SessionLocal
from .library import load_library, now_iso, save_library_with_backup
from .models import Connection, Device


class OfflineMusicTokenVerifier(TokenVerifier):
    async def verify_token(self, token: str) -> AccessToken | None:
        try:
            payload = decode_access_token(token)
            connection_id = uuid.UUID(payload["connection_id"])
            device_id = uuid.UUID(payload["sub"])
        except Exception:
            return None
        async with SessionLocal() as session:
            connection = await session.get(Connection, connection_id)
            if not connection or connection.device_id != device_id or connection.revoked_at:
                return None
            connection.last_used_at = now_utc()
            await session.commit()
        return AccessToken(
            token=token, client_id=payload.get("client_id", "chatgpt"),
            scopes=payload.get("scope", READ_SCOPE).split(), expires_at=payload.get("exp"),
            resource=payload.get("aud"), subject=str(device_id), claims={"connection_id": str(connection_id)},
        )


def identity(scope: str) -> uuid.UUID:
    token = get_access_token()
    if not token or scope not in token.scopes or not token.subject:
        raise HTTPException(403, f"Required scope: {scope}")
    return uuid.UUID(token.subject)


async def mutate(device_id: uuid.UUID, operation) -> Any:
    async with SessionLocal() as session:
        device = await session.scalar(
            select(Device).where(Device.id == device_id).with_for_update()
        )
        if not device:
            raise HTTPException(404, "Library not found")
        library = load_library(device)
        result = operation(library)
        await save_library_with_backup(session, device, library, reason="mcp-mutation")
        await session.commit()
        return result


def find(items: list[dict], item_id: str, kind: str) -> dict:
    item = next((value for value in items if value.get("id") == item_id), None)
    if not item:
        raise HTTPException(404, f"{kind} not found")
    return item


def clean_tag(tag: str) -> str:
    return " ".join(str(tag).split()).strip("#").strip()


def tag_key(tag: str) -> str:
    return clean_tag(tag).casefold()


def normalized_tags(tags: list[str]) -> list[str]:
    """Trimmed, without '#', without case-insensitive duplicates; first spelling wins."""
    seen: set[str] = set()
    result = []
    for tag in tags:
        cleaned = clean_tag(tag)
        if cleaned and tag_key(cleaned) not in seen:
            seen.add(tag_key(cleaned))
            result.append(cleaned)
    return result


def library_spelling(library: dict, tags: list[str]) -> list[str]:
    """Reuses the spelling a tag already has somewhere in the library."""
    known = {tag_key(tag): tag for track in library["tracks"] for tag in track.get("tags") or []}
    return [known.get(tag_key(tag), tag) for tag in normalized_tags(tags)]


def tag_counts(tracks: list[dict]) -> list[dict]:
    counts: dict[str, dict] = {}
    for track in tracks:
        for tag in track.get("tags") or []:
            entry = counts.setdefault(tag_key(tag), {"tag": tag, "track_count": 0})
            entry["track_count"] += 1
    return sorted(counts.values(), key=lambda item: (-item["track_count"], item["tag"].casefold()))


def checked_url(value: str | None) -> str | None:
    if value is None or not value.strip():
        return None
    parsed = urlparse(value.strip())
    if parsed.scheme != "https" or not parsed.netloc:
        raise HTTPException(400, "Only public HTTPS URLs are supported")
    return value.strip()


def create_mcp() -> FastMCP:
    host = urlparse(public_base_url()).netloc
    mcp = FastMCP(
        "Offline Music",
        instructions=(
            "Manage the user's Offline Music library. Albums are the playlists shown in the app. "
            "Tracks can carry free-form tags the user invents (for example 'gym' or 'calm'); the app lets the user "
            "filter an album by tags, so use tag_tracks to label many tracks at once and list_tags to reuse existing "
            "spellings. remove_track_from_album takes a track out of one playlist and keeps it in the library; "
            "delete_track removes it everywhere. "
            "Never claim an audio file was downloaded unless audio_url was provided. Album deletion is not available."
        ),
        token_verifier=OfflineMusicTokenVerifier(),
        auth=AuthSettings(issuer_url=public_base_url(), resource_server_url=resource_url(), required_scopes=[READ_SCOPE]),
        stateless_http=True, json_response=True, streamable_http_path="/mcp",
        transport_security=TransportSecuritySettings(
            enable_dns_rebinding_protection=True,
            allowed_hosts=[host, f"{host}:*", "localhost:*", "127.0.0.1:*", "testserver"],
            allowed_origins=[public_base_url(), "https://chatgpt.com", "https://chat.openai.com", "http://localhost:*"],
        ),
    )
    read = ToolAnnotations(readOnlyHint=True, destructiveHint=False, openWorldHint=False)
    write = ToolAnnotations(readOnlyHint=False, destructiveHint=False, openWorldHint=False)
    delete = ToolAnnotations(readOnlyHint=False, destructiveHint=True, openWorldHint=False)

    @mcp.tool(name="list_albums", description="List all albums and their track IDs. Album deletion is intentionally unavailable.", annotations=read)
    async def list_albums() -> dict:
        device_id = identity(READ_SCOPE)
        async with SessionLocal() as session:
            device = await session.get(Device, device_id)
            albums = load_library(device)["albums"] if device else []
            return {"albums": albums, "count": len(albums)}

    @mcp.tool(name="list_tracks", description="List all tracks, optionally only tracks in one album and/or with a tag.", annotations=read)
    async def list_tracks(album_id: str | None = None, tag: str | None = None) -> dict:
        device_id = identity(READ_SCOPE)
        async with SessionLocal() as session:
            device = await session.get(Device, device_id)
            library = load_library(device) if device else {"tracks": [], "albums": []}
            tracks = library["tracks"]
            if album_id:
                album = find(library["albums"], album_id, "Album")
                allowed = set(album.get("track_ids", []))
                tracks = [track for track in tracks if track.get("id") in allowed]
            if tag:
                tracks = [track for track in tracks if tag_key(tag) in {tag_key(item) for item in track.get("tags") or []}]
            return {"tracks": tracks, "count": len(tracks)}

    @mcp.tool(name="list_tags", description="List every tag with how many tracks carry it, optionally within one album.", annotations=read)
    async def list_tags(album_id: str | None = None) -> dict:
        device_id = identity(READ_SCOPE)
        async with SessionLocal() as session:
            device = await session.get(Device, device_id)
            library = load_library(device) if device else {"tracks": [], "albums": []}
        tracks = library["tracks"]
        if album_id:
            allowed = set(find(library["albums"], album_id, "Album").get("track_ids", []))
            tracks = [track for track in tracks if track.get("id") in allowed]
        return {"tags": tag_counts(tracks)}

    @mcp.tool(name="search_library", description="Search track title, artist, album metadata and lyrics.", annotations=read)
    async def search_library(query: str) -> dict:
        device_id = identity(READ_SCOPE)
        needle = query.casefold().strip()
        async with SessionLocal() as session:
            device = await session.get(Device, device_id)
            library = load_library(device) if device else {"tracks": [], "albums": []}
        tracks = [
            item for item in library["tracks"]
            if needle in " ".join([str(item.get(key, "")) for key in ("title", "artist", "album", "lyrics")] + list(item.get("tags") or [])).casefold()
        ]
        albums = [item for item in library["albums"] if needle in str(item.get("name", "")).casefold()]
        return {"tracks": tracks, "albums": albums}

    @mcp.tool(name="create_album", description="Create an album. There is deliberately no tool for deleting albums.", annotations=write)
    async def create_album(name: str, cover_url: str | None = None) -> dict:
        device_id = identity(WRITE_SCOPE)
        clean_name = name.strip()
        if not clean_name:
            raise HTTPException(400, "Album name is required")
        cover = checked_url(cover_url)
        def operation(library):
            album = {"id": str(uuid.uuid4()), "name": clean_name, "track_ids": [], "cover_url": cover, "updated_at": now_iso()}
            library["albums"].append(album)
            return album
        return await mutate(device_id, operation)

    @mcp.tool(name="update_album", description="Rename an album and/or set its cover. Album deletion is not supported.", annotations=write)
    async def update_album(album_id: str, name: str | None = None, cover_url: str | None = None) -> dict:
        device_id = identity(WRITE_SCOPE)
        cover = checked_url(cover_url)
        def operation(library):
            album = find(library["albums"], album_id, "Album")
            if name is not None and name.strip(): album["name"] = name.strip()
            if cover_url is not None: album["cover_url"] = cover
            album["updated_at"] = now_iso()
            return album
        return await mutate(device_id, operation)

    @mcp.tool(name="add_track", description="Add a track. For offline playback provide a direct public HTTPS audio_url; cover_url is optional.", annotations=write)
    async def add_track(
        title: str, artist: str = "Unknown Artist", album: str = "Unknown Album", album_id: str | None = None,
        audio_url: str | None = None, cover_url: str | None = None, lyrics: str | None = None,
        duration_seconds: float = 0,
    ) -> dict:
        device_id = identity(WRITE_SCOPE)
        audio, cover = checked_url(audio_url), checked_url(cover_url)
        if not title.strip(): raise HTTPException(400, "Track title is required")
        def operation(library):
            track = {
                "id": str(uuid.uuid4()), "title": title.strip(), "artist": artist.strip() or "Unknown Artist",
                "album": album.strip() or "Unknown Album", "duration": max(duration_seconds, 0),
                "audio_url": audio, "cover_url": cover, "lyrics": lyrics.strip() if lyrics else None,
                "date_added": now_iso(), "updated_at": now_iso(),
            }
            library["tracks"].append(track)
            if album_id:
                target = find(library["albums"], album_id, "Album")
                target.setdefault("track_ids", []).append(track["id"])
                target["updated_at"] = now_iso()
            return track
        return await mutate(device_id, operation)

    @mcp.tool(name="update_track", description="Update track metadata or its direct audio URL.", annotations=write)
    async def update_track(
        track_id: str, title: str | None = None, artist: str | None = None, album: str | None = None,
        audio_url: str | None = None, duration_seconds: float | None = None,
    ) -> dict:
        device_id = identity(WRITE_SCOPE)
        audio = checked_url(audio_url)
        def operation(library):
            track = find(library["tracks"], track_id, "Track")
            for key, value in (("title", title), ("artist", artist), ("album", album)):
                if value is not None and value.strip(): track[key] = value.strip()
            if audio_url is not None: track["audio_url"] = audio
            if duration_seconds is not None: track["duration"] = max(duration_seconds, 0)
            track["updated_at"] = now_iso()
            return track
        return await mutate(device_id, operation)

    @mcp.tool(name="set_track_cover", description="Set or replace a track cover from a public HTTPS image URL.", annotations=write)
    async def set_track_cover(track_id: str, cover_url: str) -> dict:
        device_id = identity(WRITE_SCOPE); cover = checked_url(cover_url)
        def operation(library):
            track = find(library["tracks"], track_id, "Track"); track["cover_url"] = cover; track["updated_at"] = now_iso(); return track
        return await mutate(device_id, operation)

    @mcp.tool(name="set_album_cover", description="Set or replace an album cover from a public HTTPS image URL.", annotations=write)
    async def set_album_cover(album_id: str, cover_url: str) -> dict:
        device_id = identity(WRITE_SCOPE); cover = checked_url(cover_url)
        def operation(library):
            album = find(library["albums"], album_id, "Album"); album["cover_url"] = cover; album["updated_at"] = now_iso(); return album
        return await mutate(device_id, operation)

    @mcp.tool(name="set_track_lyrics", description="Set or replace the full lyrics for any track.", annotations=write)
    async def set_track_lyrics(track_id: str, lyrics: str) -> dict:
        device_id = identity(WRITE_SCOPE)
        def operation(library):
            track = find(library["tracks"], track_id, "Track"); track["lyrics"] = lyrics.strip() or None; track["updated_at"] = now_iso(); return track
        return await mutate(device_id, operation)

    @mcp.tool(name="set_track_tags", description="Replace all tags of one track. An empty list removes every tag.", annotations=write)
    async def set_track_tags(track_id: str, tags: list[str]) -> dict:
        device_id = identity(WRITE_SCOPE)
        def operation(library):
            track = find(library["tracks"], track_id, "Track")
            track["tags"] = library_spelling(library, tags) or None
            track["updated_at"] = now_iso()
            return track
        return await mutate(device_id, operation)

    @mcp.tool(
        name="tag_tracks",
        description="Add and/or remove tags on many tracks at once. Tags are free-form words; '#' is optional.",
        annotations=write,
    )
    async def tag_tracks(track_ids: list[str], add: list[str] | None = None, remove: list[str] | None = None) -> dict:
        device_id = identity(WRITE_SCOPE)
        if not add and not remove:
            raise HTTPException(400, "Nothing to add or remove")
        def operation(library):
            to_add = library_spelling(library, add or [])
            to_remove = {tag_key(tag) for tag in remove or []}
            changed = []
            for track_id in dict.fromkeys(track_ids):
                track = find(library["tracks"], track_id, "Track")
                before = list(track.get("tags") or [])
                after = normalized_tags([tag for tag in before if tag_key(tag) not in to_remove] + to_add)
                if after != before:
                    track["tags"] = after or None
                    track["updated_at"] = now_iso()
                    changed.append({"id": track_id, "title": track.get("title"), "tags": after})
            return {"changed": changed, "changed_count": len(changed)}
        return await mutate(device_id, operation)

    @mcp.tool(name="add_track_to_album", description="Add an existing track to an album.", annotations=write)
    async def add_track_to_album(track_id: str, album_id: str) -> dict:
        device_id = identity(WRITE_SCOPE)
        def operation(library):
            find(library["tracks"], track_id, "Track"); album = find(library["albums"], album_id, "Album")
            if track_id not in album.setdefault("track_ids", []): album["track_ids"].append(track_id)
            album["updated_at"] = now_iso(); return album
        return await mutate(device_id, operation)

    @mcp.tool(
        name="remove_track_from_album",
        description="Remove a track from an album (playlist). The track stays in the library and in other albums.",
        annotations=write,
    )
    async def remove_track_from_album(track_id: str, album_id: str) -> dict:
        device_id = identity(WRITE_SCOPE)
        def operation(library):
            album = find(library["albums"], album_id, "Album"); album["track_ids"] = [item for item in album.get("track_ids", []) if item != track_id]; album["updated_at"] = now_iso(); return album
        return await mutate(device_id, operation)

    @mcp.tool(name="delete_track", description="Permanently remove a track from the library and every album. Album deletion is not available.", annotations=delete)
    async def delete_track(track_id: str) -> dict:
        device_id = identity(DELETE_SCOPE)
        def operation(library):
            find(library["tracks"], track_id, "Track")
            library["tracks"] = [item for item in library["tracks"] if item.get("id") != track_id]
            library["track_tombstones"] = [item for item in library["track_tombstones"] if item.get("id") != track_id]
            library["track_tombstones"].append({"id": track_id, "updated_at": now_iso()})
            for album in library["albums"]: album["track_ids"] = [item for item in album.get("track_ids", []) if item != track_id]
            return {"deleted_track_id": track_id}
        return await mutate(device_id, operation)

    return mcp


offline_music_mcp = create_mcp()
