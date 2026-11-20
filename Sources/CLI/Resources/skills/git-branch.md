---
name: git-branch
description: Create feature branches, sync a branch with its base, and resolve merge conflicts. Use when the user asks to branch off, merge, rebase, or resolve a conflict.
---
# Git Branch

Create a new branch, sync it with the base branch, and resolve merge conflicts without losing work.

Only follow this skill when the user explicitly asked to create a branch, merge, rebase, or resolve a conflict. Never force-push, delete branches, or rewrite already-pushed shared history as part of it.

## Procedure

1. **Check the state of the repository.**
   - Run `git status --porcelain`. If the working tree is dirty, stop and ask the user whether to stash, commit, or carry the changes over — do not stash or commit on the user's behalf without confirmation.
   - Run `git branch --show-current` and `git branch -a` to see the current branch and the existing naming conventions.
   - Identify the base branch the work targets (usually `main` or `master`; check `git remote show origin` for the default branch if unsure).

2. **Create the branch (if asked to branch off).**
   - Match the repo's existing branch naming style from `git branch -a` (e.g. `feature/…`, `fix/…`, or bare names).
   - Create it from an up-to-date base:

     ```sh
     git fetch origin
     git checkout -b <branch-name> origin/<base-branch>
     ```

3. **Sync the branch (if asked to merge or rebase).**
   - Run `git fetch origin` first.
   - Use whichever strategy the user named. If they did not, follow the repo's convention: prefer `git rebase origin/<base-branch>` for a local-only branch or a team that uses linear history, and `git merge origin/<base-branch>` otherwise.
   - If a conflict occurs, continue to step 4.

4. **Resolve conflicts.**
   - Run `git status` to list the conflicted files.
   - Open each conflicted file and read both sides of every conflict (`<<<<<<<` / `=======` / `>>>>>>>` markers) before deciding anything.
   - Resolve by intent: when the two sides change different lines, keep both. When they change the same lines, combine the changes so the code compiles and does what both sides intended. Never keep only one side, and never delete code, to silence a conflict.
   - Remove all conflict markers, then mark the file resolved with `git add <paths>`.

5. **Finish and verify.**
   - Complete the in-flight operation: `git rebase --continue` or commit the merge. `git rebase --abort` is always safer than forcing through.
   - Run `git log --oneline --graph -10` to confirm the branch is where it should be.
   - Build the project and run the tests if the conflict touched source files.
   - Report the branch name, the outcome, and how each conflict was resolved. Do not push unless asked.
