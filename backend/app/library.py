from __future__ import annotations

from copy import deepcopy
from datetime import datetime, timezone
import json
from typing import Any

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from .models import Device, DeviceLibraryBackup


EMPTY_LIBRARY: dict[str, Any] = {
    "tracks": [],
    "albums": [],
    "track_tombstones": [],
    "album_tombstones": [],
}


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def load_library(device: Device) -> dict[str, Any]:
    try:
        raw = json.loads(device.library_json)
    except (TypeError, json.JSONDecodeError):
        raw = {}
    result = deepcopy(EMPTY_LIBRARY)
    for key in result:
        if isinstance(raw.get(key), list):
            result[key] = raw[key]
    return result


async def save_library_with_backup(
    session: AsyncSession,
    device: Device,
    library: dict[str, Any],
    *,
    reason: str,
) -> bool:
    encoded = json.dumps(library, ensure_ascii=False, separators=(",", ":"))
    if encoded == device.library_json:
        return False

    session.add(DeviceLibraryBackup(
        device_id=device.id,
        library_json=device.library_json,
        revision=device.revision,
        reason=reason[:64],
    ))
    device.library_json = encoded
    device.revision += 1
    await session.flush()

    expired_ids = list((await session.scalars(
        select(DeviceLibraryBackup.id)
        .where(DeviceLibraryBackup.device_id == device.id)
        .order_by(DeviceLibraryBackup.created_at.desc(), DeviceLibraryBackup.id.desc())
        .offset(30)
    )).all())
    if expired_ids:
        await session.execute(delete(DeviceLibraryBackup).where(DeviceLibraryBackup.id.in_(expired_ids)))
    return True


def _timestamp(item: dict[str, Any]) -> datetime:
    value = item.get("updated_at") or "1970-01-01T00:00:00Z"
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
    except ValueError:
        return datetime.min.replace(tzinfo=timezone.utc)


def _merge_items(current: list[dict[str, Any]], incoming: list[dict[str, Any]]) -> list[dict[str, Any]]:
    merged = {str(item.get("id")): item for item in current if item.get("id")}
    for item in incoming:
        item_id = str(item.get("id") or "")
        if item_id and (item_id not in merged or _timestamp(item) >= _timestamp(merged[item_id])):
            merged[item_id] = item
    return list(merged.values())


def merge_library(device: Device, incoming: dict[str, Any]) -> dict[str, Any]:
    current = load_library(device)
    current["tracks"] = _merge_items(current["tracks"], incoming.get("tracks", []))
    current["albums"] = _merge_items(current["albums"], incoming.get("albums", []))
    current["track_tombstones"] = _merge_items(
        current["track_tombstones"], incoming.get("track_tombstones", [])
    )
    current["album_tombstones"] = _merge_items(
        current["album_tombstones"], incoming.get("album_tombstones", [])
    )

    track_deleted = {item["id"]: _timestamp(item) for item in current["track_tombstones"] if item.get("id")}
    album_deleted = {item["id"]: _timestamp(item) for item in current["album_tombstones"] if item.get("id")}
    current["tracks"] = [
        item for item in current["tracks"]
        if _timestamp(item) > track_deleted.get(item.get("id"), datetime.min.replace(tzinfo=timezone.utc))
    ]
    current["albums"] = [
        item for item in current["albums"]
        if _timestamp(item) > album_deleted.get(item.get("id"), datetime.min.replace(tzinfo=timezone.utc))
    ]
    active_track_ids = {item["id"] for item in current["tracks"]}
    for album in current["albums"]:
        album["track_ids"] = [track_id for track_id in album.get("track_ids", []) if track_id in active_track_ids]

    return current
