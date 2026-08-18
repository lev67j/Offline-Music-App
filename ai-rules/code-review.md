# Code Review Rules

## Priority Order

1. Data loss or corruption.
2. Security/privacy leaks.
3. Race conditions and concurrency bugs.
4. Broken public contracts.
5. Migration/deploy failure.
6. Missing tests for risky behavior.
7. Performance problems on expected load.
8. Maintainability issues that will cause near-term bugs.

## Review Checklist

- Does the new code preserve existing behavior outside scope?
- Are migrations forward-compatible with existing rows?
- Are background jobs idempotent?
- Are retries safe?
- Are external calls timeout-bound?
- Are schema/API changes reflected in clients and tests?
- Are secrets absent from repo-tracked files?
- Are generated AI outputs validated?
- Are timezone/date assumptions explicit?
- Are source links and user-action links kept separate?
- Are slow external calls outside hot request paths where possible?
- Does the diff include a test for each fixed bug?

## Review Output

Lead with findings. Use file/line references. Keep summaries short. If no issues are found, say that and name remaining test gaps.

## Fix Pass

When the user asks to optimize or fix issues:

- Fix high-confidence bugs directly.
- Add regression tests for parser/API/client contracts.
- Avoid speculative refactors.
- Re-run the narrow tests that prove the fix.
