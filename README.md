# aid - AI Dispatch for OpenCode

Autonomous AI workflow system for OpenCode that handles tasks from start to PR creation, with built-in PR review capabilities.

## Features

- **Interactive Mode**: Launch OpenCode with an initial prompt that guides task input
- **GitHub Issue Integration**: Fetch and work on GitHub issues automatically
- **GitHub PR Support**: Work on PRs to implement requested changes
- **PR Review Mode**: Read-only review of PRs with automated feedback posting
- **Plain Text Tasks**: Work on any task described in plain text
- **Git Worktree Isolation**: Each task runs in its own worktree
- **Automatic Cleanup**: Graceful cleanup on exit, including unexpected closures
- **Session Management**: Track, list, and resume dispatch sessions

## Quick Start

```bash
# Interactive mode - opens OpenCode TUI with initial prompt
aid

# Direct mode - work on a GitHub issue (background execution)
aid https://github.com/user/repo/issues/123

# Work on a GitHub PR (implement requested changes, background)
aid https://github.com/user/repo/pull/456

# Review a PR without making changes (background)
aid review https://github.com/user/repo/pull/456

# Review a PR interactively with TUI
aid review --interactive https://github.com/user/repo/pull/456

# Direct mode - work on a plain text task (background execution)
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

**Interactive Mode (TUI):**
1. **Launch**: Run `aid` with no arguments to open OpenCode TUI
2. **Guided Input**: Initial prompt guides you to describe your task
3. **Direct Work**: AI works directly in your current repository
4. **Visual Interface**: Full OpenCode TUI experience with real-time updates

**Direct Mode (Background):**
1. **Parse Input**: Detects GitHub issue/PR URL or plain text task
2. **Create Worktree**: Sets up isolated git worktree with `ai/` prefixed branch
3. **Background Execution**: Runs OpenCode in non-TUI mode with minimal output
4. **Autonomous Work**: Agent implements, commits, reviews, and creates PR
5. **Cleanup**: Removes worktree and cleans state on completion

### PR Review (`aid review [--interactive] <pr-url>`)

1. **Fetch PR**: Gets PR details, diff, comments, and existing reviews
2. **Run OpenCode**: Launches OpenCode with read-only `review` agent (TUI or background)
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
│   └── ai-dispatch.sh      # Main dispatch script (aid)
├── agents/
│   ├── dispatch.md         # Autonomous dispatch agent
│   └── review.md           # Read-only review agent
├── commands/
│   ├── work-task.md        # Start working on task
│   ├── review-work.md      # Self-review changes
│   ├── create-pr.md        # Create pull request
│   └── review-pr.md        # Review a PR (read-only)
├── skills/
│   └── dispatch-workflow/  # Dispatch workflow skill
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
