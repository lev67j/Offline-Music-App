# AI Project Rules

## Operating Loop

- Start by reading project instructions, git status, manifests, tests, and the code that owns the requested behavior.
- Restate the working model before large edits: goal, current shape, target files, validation.
- Keep changes scoped. Do not reformat or refactor unrelated files.
- Preserve user work. Never revert changes you did not make unless explicitly asked.
- Validate before final response. Prefer focused tests first, then broader checks when risk warrants it.

## Prompt Contract For Users

A strong task prompt includes:

- Goal: what should change.
- Context: relevant files, errors, logs, screenshots, examples.
- Constraints: architecture, budget, style, compatibility, safety.
- Done when: tests, behavior, review criteria, deployment expectation.

If any of those are missing and the answer materially changes the implementation, inspect the repo first, then ask.

## Planning

- Use planning for ambiguous, high-risk, cross-module, data, migration, auth, payment, infra, or production tasks.
- Make plans decision-complete: interfaces, data flow, edge cases, tests, rollout.
- For small safe edits, implement directly after reading context.

## Code Review

- Lead with bugs, regressions, security, data loss, race conditions, missing tests, and deploy risks.
- Cite files and lines when possible.
- Fix issues directly when the user asked for optimization or implementation.
- Keep stylistic suggestions secondary unless they prevent real problems.

## Parallel AI Work

- One task, one branch or worktree.
- Divide ownership by subsystem or path before editing.
- Split large projects using `project-slicing.md` before starting multiple agents.
- Run preflight before work and before commit:

```bash
python3 ai-rules/scripts/codex_preflight.py --fail-on-conflicts
```

- For deeper rules, read `parallel-work.md`.

## Project Slicing

- Prefer vertical slices with explicit contracts: schema/API first, implementation second, client last.
- Avoid two agents editing the same migration, shared model, generated file, lockfile, or DTO at the same time.
- If shared contracts must change, finish and validate that change before parallel feature work resumes.
- Use `project-slicing.md` for ownership maps, handoffs, and merge order.

## AI Extraction And Structured Output

- Use strict JSON schemas for model output.
- Validate model output in ordinary code.
- Store raw input, parser version, prompt/schema version, confidence, and errors.
- Materialize only complete high-confidence records.
- Route uncertain results to review, not production.

## Completion

- State what changed.
- State what validation ran.
- State what could not be verified.
- Keep next steps concrete and directly useful.
