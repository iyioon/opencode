# aid

AI development workflow for OpenCode.

## Install

```bash
# Clone into OpenCode config
git clone https://github.com/iyioon/aid.git ~/.config/opencode

# Symlink to ~/.local/bin
mkdir -p ~/.local/bin
ln -sf ~/.config/opencode/scripts/aid.sh ~/.local/bin/aid

# If ~/.local/bin is not already in your PATH, add it
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc  # or ~/.zshrc
source ~/.bashrc  # or ~/.zshrc
```

**Requirements:** `git`, `gh` (authenticated), `opencode`, `jq`

## Usage

```bash
aid new "Add dark mode toggle"           # Start new task
aid new https://github.com/o/r/issues/1  # From GitHub issue
aid new https://github.com/o/r/pull/1    # From GitHub PR (fetches description, comments, reviews)
aid status                               # List tasks
aid view <task-id>                       # Open PR in browser
aid <task-id>                            # Address feedback or conflicts (auto-merges if approved)
aid approve <task-id>                    # Manually merge and cleanup
aid remove <task-id>                     # Remove a task (use --force for open PRs)
aid cleanup                              # Remove merged tasks
```

### `aid new <pr-url>` vs `aid <pr-url>`

- **`aid new <pr-url>`** — Adopt a PR that isn't tracked locally. Creates a new task, fetches the PR description, comments, reviews, and merge conflict status, checks out the PR branch, and launches the AI agent with all that context. Use this for PRs created outside of `aid` (e.g. from another machine, or by a teammate).

- **`aid <pr-url>`** — Resume a PR that is already tracked locally (created by a previous `aid new`). Looks up the existing task by its PR URL and re-fetches live feedback. Fails if no local task tracks that PR — use `aid new <pr-url>` instead.

## Workflow

```
aid new "task" → AI works → PR created → Human reviews → aid <id> (auto-merge)
```

1. `aid new` creates a worktree and launches OpenCode
2. AI explores → plans → implements → self-reviews → creates PR
3. Human reviews PR on GitHub:
   - **Approve**: `aid <task-id>` auto-merges and cleans up
   - **Request changes**: `aid <task-id>` addresses feedback
   - **Merge conflicts**: `aid <task-id>` detects conflicts and assigns AI to fix
4. `aid approve <task-id>` to manually merge if needed

## Statuses

| Status | Meaning |
|--------|---------|
| `working` | AI is actively working |
| `awaiting-review` | PR created, waiting for human |
| `needs-changes` | Human requested changes |

## Task Removal

To manually delete a task's local environment (worktree, branch, config):

```bash
aid remove <task-id>
```

- **Open PRs**: Fails by default to prevent losing unmerged work. Use `--force` to delete the local task (the PR on GitHub will remain open).
- **Merged/Closed**: Safely deletes the local artifacts. Useful if you want to clean up a specific task without running a full `cleanup`.

## Guides

- [Multi-Device Workflow](docs/multi-device-workflow.md) - Best practices for using `aid` across multiple machines.

## Structure

```
~/.config/opencode/
├── scripts/aid.sh      # CLI
├── agents/
│   ├── dispatch.md     # Task orchestrator
│   └── reviewer.md     # Code review subagent
├── commands/
│   ├── work.md         # /work command
│   └── create-pr.md    # /create-pr command
├── tasks/              # Task state
└── worktrees/          # Git worktrees
```

## License

MIT
