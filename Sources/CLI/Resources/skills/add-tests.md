---
name: add-tests
description: Write unit tests for new or changed code, following the repository's existing test conventions. Use when the user asks to add, write, or improve tests.
---
# Add Tests

Write unit tests for new or changed code, matching how the repository already tests.

Only follow this skill when the user explicitly asked to add, write, or improve tests. Never disable, skip, or weaken a test to make it pass, and do not modify production code unless a test exposes a genuine bug and the user wants it fixed.

## Procedure

1. **Study the existing tests.**
   - Find the test target or directory that covers the code you are testing, and read two or three representative tests.
   - Note the framework (e.g. Swift Testing's `@Test`, XCTest), naming conventions, how fixtures and helpers are shared, and the command the project uses to run tests.

2. **Plan the cases.**
   - Test behavior, not implementation: the happy path, the edge cases of the changed logic, and the error paths the new code introduces.
   - Keep the set focused — cover what the change actually does, not the whole module.

3. **Write the tests.**
   - Add them to the existing test file for that type when one exists; otherwise create a new file following the directory layout of the other test files.
   - Mirror the existing patterns exactly: same framework, same helpers, same naming.
   - Make each test independent — no ordering dependencies and no shared mutable state.

4. **Run and iterate.**
   - Run just the new tests first, then the whole affected target.
   - If a test fails because the test is wrong, fix the test. If it fails because the production code has a bug, report the bug and fix it only if the user asked you to.
   - Iterate until the full target passes.

5. **Report.**
   - Report which tests were added, where they live, and the run results.
