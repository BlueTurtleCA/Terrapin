---
name: security-review
description: Perform a security audit of the codebase or a change set for vulnerabilities and leaked secrets. Use when the user asks for a security review, vulnerability check, or secret scan.
---
# Security Review

Audit code for security vulnerabilities and leaked secrets, and report concrete, actionable findings.

Only follow this skill when the user explicitly asked for a security review or a secret scan. A security review is read-only: do not modify, commit, push, or reformat any code as part of it unless the user separately asks you to apply fixes.

## Procedure

1. **Scope the review.**
   - If the user named files, a branch, or a change set, audit exactly that. If they asked for a project-wide audit, cover the whole codebase.
   - If the scope is ambiguous, default to the uncommitted work (`git diff`, `git diff --staged`, untracked files) and say so before starting.

2. **Scan for secrets and credentials.**
   - Use `grep_file` for common patterns: `api[_-]?key`, `secret`, `password`, `token`, `BEGIN (RSA|EC|OPENSSH|DSA) PRIVATE KEY`, AWS keys (`AKIA[0-9A-Z]{16}`), OpenAI keys (`sk-`), GitHub tokens (`ghp_`, `gho_`), and high-entropy strings assigned to suspicious variables.
   - Check for credential files in the tree (`.env`, `*.pem`, `*.key`, `*.p12`, `*.jks`, `credentials*.json`, `id_rsa*`) and confirm `.gitignore` covers them.
   - Check whether secrets were ever committed: `git log --all --oneline -S'<distinctive fragment>' -- <path>`.
   - Report every hit by file, line, and type only — never echo the secret value itself. If a live secret is committed, say so and note that rotation is required; rewriting history is the user's decision.

3. **Audit the code for vulnerabilities.**
   - **Injection:** shell, SQL, or HTML command strings built from untrusted input without parameterization or escaping.
   - **Path and input handling:** file paths from user input without normalization or sandbox checks, unsafe deserialization, `eval` of untrusted data.
   - **Cryptography:** hardcoded keys or salts, weak algorithms used for security (MD5, SHA-1, ECB mode), non-cryptographic randomness for tokens or sessions.
   - **Exposure:** debug endpoints or verbose error messages left in production paths, over-permissive file permissions, platform entitlements or URL-scheme handlers broader than needed.
   - **Dependencies:** read the lockfile for the direct dependencies and, only if the user asked or a version looks old, check the web for known CVEs in them.
   - Prefer the project's own tools when they exist (linters, secret scanners configured in the repo) before hand-rolled greps.

4. **Report the findings.**
   - Group findings by severity: **critical** (active exposure, e.g. committed live secret), **high** (exploitable with modest effort), **medium**, **low** (hardening).
   - Every finding needs a file:line reference, the vulnerability type, the concrete risk, and a specific fix. No vague praise or filler.
   - If nothing is found, say so in one line and name exactly what you checked — a clean security review is only as good as the description of its scope.
