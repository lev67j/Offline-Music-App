# AI Rules Pack

Copy this `ai-rules/` folder into any project to give AI coding agents a durable working system.

## What Is Inside

- `AGENTS.md` - short standing instructions for coding agents.
- `prompting.md` - how to ask for implementation, debugging, architecture, and review work.
- `project-slicing.md` - how to split a codebase into independent AI-safe work zones.
- `parallel-work.md` - branch/worktree protocol for 2+ agents or developers.
- `architecture.md` - decision rules for data, APIs, workers, AI, and migrations.
- `code-review.md` - review checklist and output shape.
- `mac-self-host.md` - local Mac production-like testing notes.
- `templates/` - reusable task and review prompts.
- `scripts/codex_preflight.py` - non-mutating git safety check.

Recommended setup:

1. Copy `ai-rules/` into the repository root.
2. Add a root `AGENTS.md` with:

```md
# Agent Instructions

Use the reusable project rules in `ai-rules/AGENTS.md`.
Add project-specific build, test, and architecture notes below.
```

3. Keep root `AGENTS.md` short. Put reusable detail in this folder.
4. Run `python3 ai-rules/scripts/codex_preflight.py` before large edits and before commits.

The pack is based on official guidance from OpenAI Codex, OpenAI structured outputs, Anthropic Claude Code, and Google prompt-design docs. See `sources.md`.
