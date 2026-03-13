# Configuration

## Directory Locations

| Path | Purpose |
|------|---------|
| `~/.config/opencode/scripts/` | Script files including aid.sh |
| `~/.config/opencode/agents/` | Agent definitions (dispatch.md) |
| `~/.config/opencode/commands/` | Custom commands |
| `~/.config/opencode/dispatch/` | Session state files (JSON) |
| `~/.config/opencode/worktrees/` | Git worktrees for tasks |

## Customizing the Development Agent

Edit `~/.config/opencode/agents/dispatch.md` to customize the agent behavior.

### Change the Model

```yaml
---
model: github-copilot/claude-sonnet-4  # Change this
temperature: 0.3
---
```

Available models depend on your OpenCode configuration.

### Adjust Temperature

- Lower (0.1-0.3): More focused, deterministic responses
- Higher (0.5-0.8): More creative, varied approaches

```yaml
---
temperature: 0.5  # More creative
---
```

### Modify Permissions

The default permissions allow full autonomy:

```yaml
permission:
  edit: allow
  bash:
    "*": allow
    "git push *": allow
    "gh pr create *": allow
```

To require approval for certain operations:

```yaml
permission:
  edit: allow
  bash:
    "*": allow
    "git push *": ask        # Ask before pushing
    "rm -rf *": deny         # Never allow rm -rf
```

## Custom Commands

The development workflow uses three commands:

### /work-task
Starts working on the assigned task. Edit `~/.config/opencode/commands/work-task.md`.

### /review-work
Reviews changes before PR. Edit `~/.config/opencode/commands/review-work.md`.

### /create-pr
Creates the pull request. Edit `~/.config/opencode/commands/create-pr.md`.

## OpenCode Global Config

The `opencode.json` includes:

```json
{
  "permission": {
    "external_directory": {
      "~/.config/opencode/worktrees/**": "allow"
    }
  }
}
```

This allows OpenCode to work in the worktrees directory.

## Branch Naming

The system uses a unique session ID for all branches to avoid collisions.

Format: `aid/<YYYYMMDD-HHMMSS-PID>`
Example: `aid/20250312-143022-1234`

The worktree directory also uses this session ID.

To change the prefix, edit `~/.config/opencode/scripts/aid.sh`:

```bash
# Find this line and change "aid/" to your preferred prefix
branch_name="aid/${session_id}"
```

## Target Branch for PRs

By default, PRs are created against the default branch (usually `main` or `master`).

The script auto-detects this from `refs/remotes/origin/HEAD`.

## State File Format

Session state is stored in JSON:

```json
{
  "session_id": "20250312-143022-1234",
  "branch_name": "aid/20250312-143022-1234",
  "worktree_path": "/Users/you/.config/opencode/worktrees/20250312-143022-1234",
  "task_type": "github_issue",
  "task_source": "https://github.com/owner/repo/issues/123",
  "task_description": "...",
  "source_repo": "/path/to/your/project",
  "created_at": "2025-03-12T14:30:22Z",
  "status": "running",
  "pid": 12345
}
```

Status values: `running`, `completed`, `failed`, `orphaned`
