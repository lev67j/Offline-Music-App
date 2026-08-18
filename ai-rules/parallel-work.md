# Parallel AI Work Protocol

Use this when multiple AI sessions or developers work in the same repo.

## Setup

- Prefer separate worktrees:

```bash
git worktree add ../project-task-name -b codex/task-name HEAD
```

- Never check out the same branch in two worktrees.
- Declare ownership before editing:
  - backend worker
  - API/schema
  - frontend/client
  - infra/deploy
  - docs/rules
- Keep a short ownership note in the issue, PR description, or task brief.
- Start with contract work if multiple slices need the same model/API change.

## During Work

- Do not run broad formatters across files owned by another session.
- Do not rename shared files while another session is editing them.
- Pull/fetch before long work.
- If another change appears in a file you need, inspect it and integrate; do not overwrite.
- Commit or checkpoint small slices before starting risky edits.
- If you need a path owned by another agent, pause and coordinate instead of making a hidden dependency.

## Before Commit

```bash
python3 ai-rules/scripts/codex_preflight.py --fail-on-conflicts
git diff --check
git diff --stat
```

Stage exact files only:

```bash
git add path/to/file1 path/to/file2
```

## Merge Order

1. Shared schema/contracts.
2. Backend implementation.
3. API/client adaptation.
4. UI polish.
5. Docs and cleanup.

## Conflict Handling

- Read both sides and surrounding code.
- Preserve both intended behaviors when possible.
- Resolve only files in your ownership area unless assigned otherwise.
- Rerun tests affected by both branches.
- Mention the conflict and resolution in the final summary.

## Handoff Note

Use this shape when handing work to another agent:

```md
Current branch/worktree:
Goal:
Done:
Changed files:
Validation passed:
Known failures:
Next safe step:
Do not touch:
```
