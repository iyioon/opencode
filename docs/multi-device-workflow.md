# Multi-Device Workflow with `aid`

When using `aid` across multiple devices (e.g., a laptop and a desktop), you need to be aware of how local state is managed to avoid conflicts and lost work. `aid` relies heavily on local filesystem structures (worktrees and task state files) which do not automatically sync between machines.

## Potential Problems

### 1. Local Task State Isolation
`aid` stores task metadata in `~/.config/opencode/tasks/`. 
- **Problem:** If you start a task on Device A (`aid new "Fix bug"`), Device B will not know about this task. `aid status` on Device B will show an empty list or different tasks.
- **Consequence:** You might accidentally start working on the same issue on Device B, creating duplicate effort or conflicts.

### 2. Git Worktree paths are Local
`aid` creates git worktrees in `~/.config/opencode/worktrees/`.
- **Problem:** These are absolute paths specific to the machine. You cannot simply sync this directory (via Dropbox/Syncthing) to another machine because the git worktree metadata contains absolute paths that will break if the username or directory structure differs.
- **Consequence:** You cannot "resume" a shell session or worktree state from one device to another directly.

### 3. Divergent Branches
- **Problem:** If you edit a branch on Device A but forget to push, Device B will be working from an outdated version of that branch.
- **Consequence:** Merge conflicts when you finally push from both devices.

### 4. Environment Drift
- **Problem:** Different versions of dependencies (node, python, go, etc.) or system tools on different devices.
- **Consequence:** `aid` might succeed on one machine but fail on another due to missing tools or version mismatches in the generated code/tests.

## Mitigation Strategies

### 1. Treat GitHub as the Source of Truth
Since local state isn't shared, rely on the remote repository.
- **Always push your changes** before switching devices, even if the work is incomplete (use "WIP" commits).
- **Check GitHub Issues/PRs** to see what is currently being worked on, rather than relying solely on `aid status`.

### 2. independent Task Lifecycle
Treat each device's `aid` instance as a separate worker.
- **Don't try to sync `~/.config/opencode`**. Let each device manage its own active tasks.
- If you need to switch devices for a specific task:
    1. **Device A:** Push all changes to the feature branch.
    2. **Device B:** Run `aid new <branch-name>` or manually checkout the branch in a new task to resume work. *Note: `aid` currently creates new branches for new tasks, so you might need to manually adapt the workflow to resume an existing branch.*

### 3. Strict Git Hygiene
- **Pull frequently:** Before starting `aid new`, ensure your main/master branch is up to date.
- **Prune often:** Run `aid cleanup` regularly on each device to remove stale worktrees and keep the local state clean.

### 4. Containerized/Standardized Environments
- Use tools like `.nvmrc`, `.python-version`, or Docker containers to ensure the development environment is identical across devices. This minimizes "it works on my machine" issues when the AI generates code.

## Summary Checklist for Switching Devices

1.  **[Device A]** Commit all changes: `git commit -am "wip"`
2.  **[Device A]** Push to remote: `git push`
3.  **[Device B]** Pull changes: `git pull`
4.  **[Device B]** Create a new task or checkout the branch to continue.
