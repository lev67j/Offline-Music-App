from __future__ import annotations

from app.library import merge_library


class FakeDevice:
    library_json = """{
      "tracks":[{"id":"track-1","title":"Safe","updated_at":"2026-08-19T00:00:00Z"}],
      "albums":[{"id":"album-1","name":"Saved","track_ids":["track-1"],"updated_at":"2026-08-19T00:00:00Z"}],
      "track_tombstones":[],"album_tombstones":[]
    }"""


def test_merge_never_treats_an_empty_client_snapshot_as_deletion() -> None:
    merged = merge_library(FakeDevice(), {
        "tracks": [],
        "albums": [],
        "track_tombstones": [],
        "album_tombstones": [],
    })

    assert [track["id"] for track in merged["tracks"]] == ["track-1"]
    assert [album["id"] for album in merged["albums"]] == ["album-1"]
