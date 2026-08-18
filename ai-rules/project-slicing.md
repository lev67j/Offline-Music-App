# Project Slicing Rules

Use this when a task is large enough that two agents, two branches, or multiple subsystems may be involved.

## Slice Types

- Contract slice: schemas, migrations, DTOs, env vars, API routes, queue message shapes.
- Backend slice: services, repositories, workers, integrations, jobs.
- Client slice: frontend/mobile DTOs, view models, screens, local state.
- Infra slice: Docker, CI, deploy config, secrets shape, backups.
- Docs/rules slice: README, runbooks, architecture notes, prompts.

Do contract slices first. Parallel work is safest after contracts are merged or frozen.

## Ownership Map

Before editing, write down:

```md
Task:
Branch/worktree:
Owner:
Owned paths:
Shared contracts touched:
Do not touch:
Validation:
Handoff notes:
```

## Good Splits

- Parser logic and parser tests in one slice.
- API schemas/routes and client DTO updates in separate slices after the API contract is known.
- Docker/CI changes separate from application logic unless the app cannot run without them.
- Docs updates after behavior is implemented, unless docs are the task.

## Bad Splits

- Two agents editing one migration chain.
- Two agents changing the same shared model or DTO.
- One agent renaming files while another edits imports.
- Broad formatting mixed with behavior changes.
- UI polish in the same slice as data-model changes.

## Contract Freeze

When a shared contract changes:

1. Define the new shape in one place.
2. Add or update contract tests.
3. Update server and client adapters.
4. Run compatibility checks.
5. Tell other agents the contract is frozen.

## Merge Order

1. Migrations and shared models.
2. Backend writes/workers.
3. Backend reads/API.
4. Client DTOs and state.
5. UI surfaces.
6. Infra and docs.

If a later slice reveals a contract problem, go back to the contract slice instead of patching around it in the client.
