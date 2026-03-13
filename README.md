# aid - Automated Development for OpenCode

A workflow automation tool for OpenCode that handles development tasks from start to pull request creation, with built-in PR review capabilities.

## Features

- **TUI Mode**: All commands run in OpenCode's visual TUI
- **GitHub Issue Integration**: Fetch and work on GitHub issues automatically
- **GitHub PR Support**: Work on PRs to implement requested changes
- **PR Review Mode**: Read-only review of PRs with automated feedback posting
- **Plain Text Tasks**: Work on any task described in plain text
- **Git Worktree Isolation**: Each task runs in its own isolated worktree
- **Automatic Cleanup**: Clean shutdown and resource management
- **Session Management**: Track, list, and resume work sessions

## Quick Start

```bash
# Interactive mode - opens OpenCode TUI with initial prompt
aid

# TUI mode - work on a GitHub issue
aid https://github.com/user/repo/issues/123

# Work on a GitHub PR (implement requested changes)
aid https://github.com/user/repo/pull/456

# Review a PR
aid review https://github.com/user/repo/pull/456

# TUI mode - work on a plain text task
aid "Add dark mode toggle to settings page"

# List active sessions
aid list

# View session details (commits, PR status, etc.)
aid view 20250312-143022-1234

# Clean up orphaned sessions
aid cleanup --force
```

## PR Review Workflow

The `aid review` command enables a human-in-the-loop workflow for AI-generated PRs:

```
┌─────────────────────────────────────────────────────────────────┐
│  1. AI creates PR via dispatch workflow                         │
│     └─> PR opened: https://github.com/owner/repo/pull/42       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  2. You run: aid review https://github.com/owner/repo/pull/42  │
│     └─> AI analyzes PR (read-only)                              │
│     └─> AI posts review comment with issues/suggestions         │
└─────────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────┴─────────┐
                    ▼                   ▼
           ┌─────────────┐      ┌─────────────────┐
           │ Looks good! │      │ Issues found    │
           └──────┬──────┘      └────────┬────────┘
                  │                      │
                  ▼                      ▼
        ┌─────────────────┐    ┌─────────────────────┐
        │ Merge & delete: │    │ Run: aid <pr-url>   │
        │ gh pr merge     │    │ → AI fixes issues   │
        │ --delete-branch │    └─────────────────────┘
        └─────────────────┘
```

### Review vs Work

| Command | Mode | Creates Worktree | Edits Files | Posts Comment |
|---------|------|------------------|-------------|---------------|
| `aid review <pr-url>` | Read-only | No | No | Yes |
| `aid <pr-url>` | Full access | Yes | Yes | Creates commits |

## Documentation

- [Installation Guide](docs/installation.md)
- [Usage Guide](docs/usage.md)
- [Configuration](docs/configuration.md)

## How It Works

**TUI Mode:**
1. **Launch**: Run any `aid` command to open OpenCode TUI
2. **Visual Interface**: Full OpenCode TUI experience with real-time updates
3. **Worktree Isolation**: Tasks run in isolated git worktrees for safety
4. **Interactive Experience**: Watch progress and interact with the AI

### PR Review (`aid review <pr-url>`)

1. **Fetch PR**: Gets PR details, diff, comments, and existing reviews
2. **Run OpenCode**: Launches OpenCode with read-only `review` agent (TUI by default)
3. **Analyze**: Agent reviews code for issues, bugs, and improvements
4. **Post Comment**: Agent posts review comment via `gh pr review`

## Agents

| Agent | Mode | Purpose | File Edits |
|-------|------|---------|------------|
| `dispatch` | Primary | Autonomous task completion, commits, PRs | Yes |
| `review` | Primary | Read-only PR review, posts comments | No |

## Commands

| Command | Description | Agent |
|---------|-------------|-------|
| `/work-task` | Analyze and begin working on a task | dispatch |
| `/review-work` | Self-review changes before PR | dispatch |
| `/create-pr` | Create pull request for completed work | dispatch |
| `/review-pr` | Review a PR and post feedback | review |

## Requirements

- `git` (with worktree support)
- `gh` (GitHub CLI, authenticated)
- `opencode`
- `jq`

## Directory Structure

```
~/.config/opencode/
├── scripts/
│   └── aid.sh              # Main script (aid)
├── agents/
│   ├── dispatch.md         # Development workflow agent
│   └── review.md           # Read-only review agent
├── commands/
│   ├── work-task.md        # Start working on task
│   ├── review-work.md      # Review changes
│   ├── create-pr.md        # Create pull request
│   └── review-pr.md        # Review a PR (read-only)
├── skills/
│   └── dispatch-workflow/  # Development workflow skill
├── dispatch/               # Session state files
├── worktrees/              # Git worktrees for tasks
└── docs/                   # Documentation
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `AID_DEBUG=1` | Enable debug output |
| `AID_DRY_RUN=1` | Show what would be done without executing |

## License

MIT
