---
name: debug-failures
description: Systematically diagnose a failing build, test, or runtime behavior and fix the root cause. Use when the user reports a failure, crash, or bug to investigate.
---
# Debug Failures

Diagnose a failing build, test, or runtime behavior and fix the root cause.

Only follow this skill when the user reported a failure or asked to investigate a bug. Never delete, disable, or skip a test to make a failure go away, and never stop at the first plausible fix.

## Procedure

1. **Reproduce the failure.**
   - Run the failing command exactly as reported, using the project's build or test command from its build files or documentation.
   - Capture the full output — all errors and warnings, not just the last line.
   - If you cannot reproduce it, say so, describe what you ran, and ask the user for the environment or exact steps. Do not guess at a fix for a failure you have not seen.

2. **Read the full diagnostic.**
   - Start from the first error, not the last: cascading failures usually repeat the first one.
   - For a test failure, read the failing assertion and the stack trace. For a crash, read the faulting instruction or exception and the frames that led to it.
   - Open the actual source at the reported location — the line number in a diagnostic is a clue, not a verdict.

3. **Isolate the cause.**
   - Narrow the blast radius: run the single failing test case, or build only the affected target.
   - If the failure appeared recently in a git repository, use `git log` or `git bisect` on the relevant files to find when it changed.
   - Form one or two concrete hypotheses from the evidence, then verify each with the cheapest experiment: a minimal reproduction, a temporary log statement, or a small code snippet run in context.

4. **Fix the root cause.**
   - Make the smallest change that addresses the cause, not the symptom.
   - Remove any temporary diagnostics you added.

5. **Verify and report.**
   - Re-run the originally failing command until it passes.
   - Run the full test suite, or at least the affected target, to confirm nothing new broke.
   - Report what was failing, the root cause, the fix, and the verification result.
