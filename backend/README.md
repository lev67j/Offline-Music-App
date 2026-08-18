---
title: Offline Music MCP
emoji: "🎵"
colorFrom: green
colorTo: gray
sdk: docker
app_port: 7860
pinned: false
---

# Offline Music MCP backend

The backend stores one encrypted-secret-scoped library per app installation and exposes the same library through REST sync and OAuth-protected MCP.

Required production environment:

- `OFFLINE_MUSIC_DATABASE_URL`: PostgreSQL connection string.
- `OFFLINE_MUSIC_JWT_SECRET`: random signing secret.
- `OFFLINE_MUSIC_PUBLIC_BASE_URL`: public HTTPS origin (including a mount path, if any) without a trailing slash.

Run locally:

```sh
cd backend
OFFLINE_MUSIC_JWT_SECRET=local-only-secret uvicorn app.main:app --reload
```

The canonical MCP URL is `${PUBLIC_BASE_URL}/mcp`.
