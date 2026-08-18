# Offline Music App

Offline Music App is a small personal iPhone project I built for myself because listening to local music offline on iPhone felt more awkward than it should.

This is not a "look how futuristic my tech stack is" app. It is a practical local player for files I already have, with a cleaner flow for importing tracks, organizing playlists, and pressing play without extra friction.

## Why I Made It

- I wanted a simple offline music experience that felt closer to my own habits.
- I wanted local file import to be straightforward instead of annoying.
- I wanted the app to stay focused and honest instead of pretending to be a giant streaming product.

## What It Does

- Imports local audio files through the system document picker.
- Reads embedded metadata such as title, artist, album, duration, and artwork.
- Lets me create playlists, shuffle them, remove tracks, and manage the queue.
- Supports custom playlist covers from Photos.
- Uses a compact bottom control island for playback controls and queue access.
- Connects the same library to ChatGPT through an OAuth-protected MCP server.
- Lets ChatGPT create albums, add tracks, set covers and lyrics, and delete tracks.
- Intentionally does not expose album deletion through MCP.

## ChatGPT / MCP

Open the gear button in the app, copy the MCP URL, and add it as a custom MCP
connection in ChatGPT. When ChatGPT opens the authorization page, return to the
same screen, generate the one-time six-digit code, and enter it there.

Tracks created through MCP become playable offline after the app downloads the
direct public HTTPS `audio_url`. Metadata-only tracks are allowed, but cannot be
played until an audio URL is added. Remote covers use the same download flow.

The production MCP URL is:

```text
https://lev11111-gtd-system-backend.hf.space/offline-music/mcp
```

## Project Shape

- Platform: iOS 17+
- UI: SwiftUI
- Project generation: XcodeGen
- Scope: personal utility app, intentionally small and direct

## Repository Layout

- `OfflineMusic/Sources` - app code, player, models, picker flow, and library state
- `OfflineMusic/Resources` - app resources and plist
- `backend` - standalone REST sync, OAuth and MCP backend
- `project.yml` - XcodeGen project description

## Open Locally

```sh
xcodegen generate
open OfflineMusic.xcodeproj
```

Then run the `OfflineMusic` target on an iPhone simulator or device.

## Status

This project exists mostly for me. The goal was not to invent a grand new music platform, just to make offline listening on iPhone less annoying.
