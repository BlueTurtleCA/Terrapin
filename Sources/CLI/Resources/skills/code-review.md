---
name: code-review
description: Review uncommitted changes or a branch diff for bugs, security issues, and convention violations. Use when the user asks to review code, changes, or a pull request.
---
# Code Review

Review a set of changes and report concrete, actionable findings.

Only follow this skill when the user explicitly asked to review code. A review is read-only: do not modify, commit, push, or reformat any code as part of it unless the user separately asks you to apply fixes.

## Procedure

1. **Scope the review.**
   - If the user named files, a branch, or a pull request, review exactly that.
   - Otherwise review the uncommitted work: `git diff`, `git diff --staged`, and any untracked files that belong to the change.
   - If there is nothing to review, say so and stop.

2. **Read the context.**
   - Read the full diff, then open each changed file around every hunk — a line in isolation is not what it looks like in a diff.
   - Run `git log --oneline -10` to understand the intent behind the change.

3. **Run the review passes.**
   - **Correctness:** logic errors, unhandled edge cases, nil and error handling, data races and other concurrency misuse.
   - **Security:** hardcoded secrets and credentials, injection, unsafe deserialization, missing input validation. Flag secrets by file and line only — never echo their values.
   - **Consistency:** naming, file layout, and API style compared against similar code already in the codebase.
   - **Tests and docs:** do the tests cover the new behavior, and do README or doc statements still match the code?
   - **Accidental damage:** leftover debug prints, commented-out code, TODOs, and files that should not be in the diff (`.env`, build artifacts).

4. **Report the findings.**
   - Group findings by severity: **blockers** (must fix), **warnings** (should fix), **suggestions** (optional).
   - Every finding needs a file:line reference, a one-line explanation of the problem, and a concrete fix. No vague praise or filler.
   - If the change is clean, say so in one line and name what you checked.
