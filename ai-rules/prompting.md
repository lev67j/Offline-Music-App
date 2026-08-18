# Prompting Rules

## Good Task Prompt

Use this structure when asking an AI agent to work:

```md
Goal:
Context:
Constraints:
Done when:
Validation to run:
Do not touch:
```

For bigger tasks, add:

```md
Public interfaces:
Data model changes:
Deployment target:
Rollback expectation:
Parallel ownership:
```

## How To Get Better Code

- Give the real error, log, screenshot, or failing test.
- Name the target behavior, not only the implementation idea.
- Say what must stay compatible.
- Say what can be ignored.
- Ask for a review pass after implementation when the change touches shared behavior.
- Ask the agent to explain the working model before large edits.
- Ask for focused tests that lock the behavior you care about.

## How To Use AI For Architecture

- Ask for alternatives only when you are actually willing to choose between them.
- Force explicit tradeoffs: speed, cost, reliability, privacy, maintenance.
- Convert the final choice into a short decision record.
- Keep v1 boring. Prefer one working path over five speculative abstractions.
- Pin public contracts early: API payloads, migrations, file formats, queues, env vars.
- Defer nice-to-have features until the first production-shaped path works.

## How To Use AI For Debugging

- Provide reproduction steps and exact expected vs actual behavior.
- Ask the agent to inspect before guessing.
- Ask for the smallest failing test that captures the bug.
- Ask for a root-cause summary after the fix.

## How To Use AI For Prompted Extraction

- Ask for strict JSON, not prose.
- Provide a schema and examples of valid and invalid outputs.
- Keep model output separate from database writes.
- Validate dates, links, identities, money, and locations with ordinary code.
- Store prompt version, schema version, confidence, and error metadata.

## Working Loop For Vibe Coding

1. Brainstorm freely in chat.
2. Convert the idea into a short task brief.
3. Let the agent inspect the repo and name the target files.
4. Implement one slice.
5. Run tests or a real app check.
6. Review the diff.
7. Commit only when the slice is stable.

## Anti-Patterns

- "Make it better" without success criteria.
- Asking many agents to edit the same files.
- Letting AI write migrations or scripts without running them.
- Accepting generated code without a diff review.
- Using AI extraction output without schema validation.
- Leaving "later" decisions hidden in code instead of writing them down.
