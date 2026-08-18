# Mac Self-Host Rules

Use this when the local Mac is the production-like environment.

## Target Shape

- Docker Compose for PostgreSQL, API, workers, and optional local AI.
- Ollama or llama.cpp exposes an OpenAI-compatible endpoint.
- Parser worker can use local model via `PARSER_WORKER_LLM_BASE_URL`.
- Cloudflare Worker remains optional cache/facade, not the source of truth.
- MacBook can be the production-like test box; Mac mini can later become the always-on box.
- Keep the same Compose and `.env` shape on both machines.

## Local Production Test

```bash
cp .env.example .env
docker compose up -d postgres
alembic upgrade head
platform-admin seed-defaults
docker compose --profile local-ai up -d ollama
docker compose up -d feed-api parser-worker telegram-collector
curl http://localhost:8000/health
```

For local AI through Compose, use:

```env
PARSER_WORKER_LLM_ENABLED=true
PARSER_WORKER_LLM_PROVIDER=ollama
PARSER_WORKER_LLM_BASE_URL=http://ollama:11434
PARSER_WORKER_LLM_MODEL=qwen3:4b
PARSER_WORKER_LLM_MAX_TOKENS=900
PARSER_WORKER_LLM_THINK=false
```

For host shell outside Compose, use:

```env
PARSER_WORKER_LLM_BASE_URL=http://localhost:11434
```

## Mac Production Notes

- Disable sleep before long-running service tests.
- Keep `.tdlib/`, `.telethon/`, Postgres volumes, and Ollama model cache out of git.
- Back up Postgres before schema changes.
- Restart workers after `.env` changes.
- Prefer one always-on collector account first; add more only after the first source is stable.
- For launch, run the stack on the always-on Mac and keep Cloudflare Tunnel/Worker in front if public access is needed.
- Treat laptop sleep as a test limitation, not an application architecture problem.
