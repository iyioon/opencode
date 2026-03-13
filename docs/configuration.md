# Configuration

## Directory Locations

| Path | Purpose |
|------|---------|
| `~/.config/opencode/scripts/` | Script files including `aid.sh` |
| `~/.config/opencode/agents/` | Agent definitions (`dispatch.md`, `review.md`) |
| `~/.config/opencode/commands/` | Custom slash commands |
| `~/.config/opencode/dispatch/` | Session state files (JSON) |
| `~/.config/opencode/worktrees/` | Git worktrees for tasks |
| `~/.config/opencode/tasks/` | Persistent task context directories |
| `~/.config/opencode/opencode.json` | OpenCode global configuration |

---

## Configuration Reference

This section documents every tunable in `aid` — what it controls, where to change it, its current default, and when you'd want to change it.

### Model

**File:** `~/.config/opencode/opencode.json` → `model`  
**Default:** `github-copilot/claude-sonnet-4.6`  
**Change when:** You want to use a different model for all sessions (e.g. a more capable model for harder tasks, or a faster/cheaper model for routine work).

```json
{
  "model": "github-copilot/claude-sonnet-4.6"
}
```

Available models depend on your OpenCode installation and provider configuration.

---

### Agent Temperature

**File:** `~/.config/opencode/agents/dispatch.md` and `~/.config/opencode/agents/review.md` → `temperature` (YAML frontmatter)  
**Default:** `0.3` (both agents)  
**Change when:** You want more creative/varied output (raise toward 0.8) or more deterministic/focused output (lower toward 0.1).

```yaml
---
temperature: 0.3
---
```

Each agent has its own temperature setting. Edit each file separately if you want them to differ.

---

### Agent System Prompt (Personality / Workflow)

**File:** `~/.config/opencode/agents/dispatch.md` (dispatch agent) and `~/.config/opencode/agents/review.md` (review agent) — the body of each file (below the YAML frontmatter)  
**Change when:** You want to change how the agent reasons, its workflow phases, commit message style, PR format, or output format.

- **Dispatch agent** (`dispatch.md`): Controls the 5-phase development workflow (Understand → Plan → Implement → Review → PR), commit conventions, and PR description template.
- **Review agent** (`review.md`): Controls review principles, severity levels, what to look for, and the exact format of the posted review comment.

---

### Runtime Prompts (Task Context Passed to the Agent)

**File:** `~/.config/opencode/scripts/aid.sh`  
**Change when:** You want to change what context or framing is passed to the agent at the start of each run.

There are two runtime prompts built by the script:

**Dispatch prompt** (`dispatch()` function):
```bash
task_prompt="## Task

${task_description}

## Context

- Worktree: ${worktree_path}
- Target branch: ${default_branch}${extra_context}"
```
This prompt is passed via `--prompt` to `opencode --agent dispatch`.

**Review prompt** (`review_pr()` function):
```bash
review_prompt="Review PR #${pr_number}: ${pr_url}

Title: ${pr_title}
Author: ${pr_author}
Changes: +${pr_additions}/-${pr_deletions} lines

## Description
...
## Prior Comments
...
## Prior Reviews
...
## Diff
..."
```
This prompt is passed via `--prompt` to `opencode --agent review`.

---

### Agent Bash Permissions

**File:** `~/.config/opencode/agents/dispatch.md` and `~/.config/opencode/agents/review.md` → `permission.bash` block (YAML frontmatter)  
**Change when:** You want to restrict (or expand) what shell commands the agent is allowed to run without approval.

**Dispatch agent** (full bash access):
```yaml
permission:
  edit: allow
  bash:
    "*": allow
  webfetch: allow
```

**Review agent** (read-only bash access):
```yaml
permission:
  bash:
    "*": deny
    "git status*": allow
    "git diff*": allow
    "git log*": allow
    "git show*": allow
    "git grep*": allow
    "gh pr view*": allow
    "gh pr diff*": allow
    "gh pr review*": allow
    "gh api repos/*/pulls/*": allow
```

To require approval for specific dispatch agent commands (e.g. force push):
```yaml
permission:
  edit: allow
  bash:
    "*": allow
    "git push --force*": ask   # Ask before force pushing
    "rm -rf *": deny           # Never allow rm -rf
```

---

### Review Agent Tool Restrictions

**File:** `~/.config/opencode/agents/review.md` → `tools` block (YAML frontmatter)  
**Default:** All write/edit tools disabled  
**Change when:** You need to allow the review agent additional capabilities (not recommended — review is intentionally read-only).

```yaml
tools:
  edit: false
  write: false
  patch: false
  multiedit: false
```

---

### MCP Servers

**File:** `~/.config/opencode/opencode.json` → `mcp`  
**Change when:** You want to add, remove, or reconfigure MCP (Model Context Protocol) tool servers available to the agents.

Current MCP servers:

```json
{
  "mcp": {
    "context7": {
      "type": "remote",
      "url": "https://mcp.context7.com/mcp",
      "headers": {
        "CONTEXT7_API_KEY": "{env:CONTEXT7_API_KEY}"
      },
      "enabled": true
    },
    "gh_grep": {
      "type": "remote",
      "url": "https://mcp.grep.app",
      "enabled": true
    }
  }
}
```

- **context7**: Provides up-to-date library documentation. Requires `CONTEXT7_API_KEY` environment variable. Set `"enabled": false` to disable.
- **gh_grep**: Provides GitHub code search. No API key required.

To disable an MCP server without removing it:
```json
"context7": {
  "enabled": false
}
```

---

### External Directory Permissions

**File:** `~/.config/opencode/opencode.json` → `permission.external_directory`  
**Default:** `~/.config/opencode/worktrees/**` is allowed  
**Change when:** Your worktrees are stored in a different location, or you want to allow/restrict OpenCode from accessing other directories.

```json
{
  "permission": {
    "external_directory": {
      "~/.config/opencode/worktrees/**": "allow"
    }
  }
}
```

This permission is required for OpenCode to read and write files inside the git worktrees that `aid` creates. If you change `WORKTREES_DIR` in `aid.sh`, update this to match.

---

### Branch Naming

**File:** `~/.config/opencode/scripts/aid.sh` → `branch_name` variable in `dispatch()` and `interactive_dispatch()`  
**Default format:** `aid/<YYYYMMDD-HHMMSS-PID>`  
**Example:** `aid/20250312-143022-1234`  
**Change when:** You prefer a different branch prefix or format.

```bash
# Find and update this line in both dispatch() and interactive_dispatch():
branch_name="aid/${session_id}"
```

---

### Session State Directory

**File:** `~/.config/opencode/scripts/aid.sh` → `DISPATCH_DIR` constant  
**Default:** `~/.config/opencode/dispatch/`  
**Change when:** You want session state files stored elsewhere.

```bash
readonly DISPATCH_DIR="${OPENCODE_CONFIG_DIR}/dispatch"
```

---

### Worktrees Directory

**File:** `~/.config/opencode/scripts/aid.sh` → `WORKTREES_DIR` constant  
**Default:** `~/.config/opencode/worktrees/`  
**Change when:** You want worktrees created in a different location. If you change this, also update `permission.external_directory` in `opencode.json`.

```bash
readonly WORKTREES_DIR="${OPENCODE_CONFIG_DIR}/worktrees"
```

---

### Target Branch for PRs

By default, PRs are created against the repository's default branch (usually `main` or `master`).

The script auto-detects this from `refs/remotes/origin/HEAD`:
```bash
default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
```

If auto-detection fails, it falls back to `main`. This value is passed as context in the task prompt but the actual PR target is determined by the `gh pr create` command in the agent.

---

## Custom Commands

Custom slash commands are defined in `~/.config/opencode/commands/`. Each file is a Markdown file with YAML frontmatter.

| Command | File | Agent | Purpose |
|---------|------|-------|---------|
| `/work-task` | `commands/work-task.md` | dispatch | Analyze and begin working on a task |
| `/review-work` | `commands/review-work.md` | dispatch | Self-review changes before PR |
| `/create-pr` | `commands/create-pr.md` | dispatch | Create pull request for completed work |
| `/review-pr` | `commands/review-pr.md` | review | Review a PR and post feedback |

To customize a command, edit the body of the corresponding `.md` file.

---

## State File Format

Session state is stored as JSON in `~/.config/opencode/dispatch/<session-id>.json`:

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

**Status values:** `running`, `completed`, `failed`, `orphaned`

**Task type values:** `github_issue`, `github_pr`, `plain_text`, `interactive`
