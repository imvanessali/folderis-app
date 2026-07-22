# Folderis Agent Instructions

- Ask a concise clarifying question only when different interpretations would materially change behavior or files.
- Once the request is clear, implement it without asking for permission.
- Keep macOS and Windows behavior aligned when a shared user-facing workflow changes.
- Preserve original user files unless the user explicitly requests an overwrite.

## Mandatory Independent Test Gate

Every task that changes code must finish with an independent testing agent:

1. The primary agent implements the change and runs focused local checks first.
2. After implementation is complete, the primary agent must spawn a separate testing agent.
3. Give the testing agent the acceptance criteria, changed-file list, relevant fixtures, and commands, but do not prescribe the expected implementation details.
4. The testing agent must inspect the resulting working tree independently and run regression tests. It must not edit production code unless the primary agent explicitly asks it to.
5. The primary agent must wait for the testing agent's report before declaring the task complete.
6. If testing fails, the primary agent fixes the defect and sends the same tester a focused retest request. Repeat until it passes or a genuine blocker is established.
7. The final response must summarize the independent test result. If sub-agents are unavailable, state that limitation and run the strongest available fallback tests instead.

For Folderis file-processing changes, the independent test should verify at minimum:

- the exact selected input scope;
- preservation of original files;
- explicit output filenames and collision behavior;
- output format and key parameters;
- whether AI was bypassed when a built-in skill should handle the task;
- cancellation/process cleanup when relevant;
- macOS and Windows compilation for shared behavior.

## Test Fixtures

- The canonical QA materials live in `test-fixtures/` (read-only master).
- Before every QA round, run `test-fixtures/reset_test_folder.sh` to refresh
  `~/Downloads/Test Folderis` from the master, then test on that copy only.
- Never test inside `test-fixtures/` and never hand-edit generated fixtures;
  adjust `make_fixtures.py` and regenerate instead (unlock/lock steps in its README).

## Workflow Improvement Review

When repeated manual work appears in the recent project history, suggest a reusable script, test harness, or skill. Do not create a new skill unless the user asks for it.
