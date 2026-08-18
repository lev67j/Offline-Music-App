# Architecture Rules

## Decision Template

```md
Decision:
Goal:
Constraints:
Chosen approach:
Rejected alternatives:
Data/API changes:
Validation:
Rollback:
```

## Defaults

- Extend existing subsystems before adding parallel ones.
- Preserve raw inputs for parsing, scraping, AI extraction, imports, and migrations.
- Make lossy transformations reviewable.
- Version prompts, schemas, parsers, and migrations.
- Prefer idempotent workers with durable cursors and unique constraints.
- Keep read APIs stable and boring.
- Put expensive work in workers, scheduled jobs, or caches.
- Keep local development and production-shaped deployment as similar as budget allows.
- Prefer reversible config switches over hard-coded environment assumptions.

## Data Pipeline Rules

- Raw input table first.
- Candidate/intermediate table second.
- Materialized public table last.
- Store confidence and parser version.
- Reprocessing must be possible.
- Production clients should only consume validated materialized data.

## AI Model Rules

- Use the model for semantic extraction, ranking, summarization, or classification.
- Do not let the model own database writes directly.
- Do not trust model dates, prices, links, identities, or addresses without validation.
- Keep deterministic fallback logic for critical paths.

## Deployment Rules

- One canonical datastore.
- Workers can be restarted without duplicating published records.
- Public APIs should tolerate worker downtime by serving the last valid materialized data.
- Secrets live in environment/config managers, never examples with real values.
- Backups are part of the architecture, not cleanup work.
