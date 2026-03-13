# aid - Automated Development for OpenCode

A workflow automation tool for OpenCode that handles development tasks from start to pull request creation, with built-in PR review capabilities and persistent task context across sessions.

## Features

- **TUI Mode**: All commands run in OpenCode's visual TUI
- **GitHub Issue Integration**: Fetch and work on GitHub issues automatically
- **GitHub PR Support**: Work on PRs to implement requested changes
- **PR Review Mode**: Read-only review of PRs with automated feedback posting
- **Plain Text Tasks**: Work on any task described in plain text
- **Git Worktree Isolation**: Each task runs in its own isolated worktree
- **Persistent Task Context**: Research notes and implementation plans survive across sessions
- **Phase Tracking**: Tasks move through research → plan → implement → review → done
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

# List all task contexts
aid tasks

# View a task's research notes and plan
aid tasks view aid-20250312-143022-1234
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
│     └─> AI analyzes PR (read-only) + injects task context       │
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
| `aid review <pr-url>` | Read-only | Yes (detached, for code exploration) | No | Yes |
| `aid <pr-url>` | Full access | Yes | Yes | Creates commits |

## Task Context System

Each task accumulates a persistent context directory that survives across sessions:

```
~/.config/opencode/tasks/<task-id>/
├── task.json      # Metadata: phase, branch, repo, PR info
├── context.md     # Agent-written research notes and decisions
└── plan.md        # Implementation plan (editable by user)
```

### Phase Lifecycle

```
research → plan → implement → review → done
```

The agent writes `context.md` during research and `plan.md` during planning. On subsequent runs, this context is injected back into the prompt so the agent resumes from where it left off — without re-researching the codebase.

### Task Commands

```bash
# List all task contexts
aid tasks

# Show task metadata, context.md, and plan.md
aid tasks view aid-20250312-143022-1234

# Edit the implementation plan before work starts
aid tasks edit aid-20250312-143022-1234 plan.md

# Manually advance or reset phase
aid tasks phase aid-20250312-143022-1234 implement

# Clean up tasks for merged/deleted branches
aid tasks cleanup --merged --force

# Clean up all task contexts
aid tasks cleanup --all --force
```

### Review with Task Context

When `aid review <pr-url>` is called, if a task context exists for that PR's branch, it is automatically injected into the review prompt:

```
--- Resuming task: aid-issue-123 (phase: review) ---

### Previous Research (context.md)
<research notes>

### Implementation Plan (plan.md)
<checklist>

---
Review PR #124: ...
```

This allows the review agent to verify that the implementation matches the original plan, skip known trade-offs, and catch deviations.

## Documentation

- [Installation Guide](docs/installation.md)
- [Usage Guide](docs/usage.md)
- [Configuration](docs/configuration.md)

## How It Works

**TUI Mode:**
1. **Launch**: Run any `aid` command to open OpenCode TUI
2. **Visual Interface**: Full OpenCode TUI experience with real-time updates
3. **Worktree Isolation**: Tasks run in isolated git worktrees for safety
4. **Task Context**: Research and plans persist across sessions automatically

### PR Review (`aid review <pr-url>`)

1. **Fetch PR**: Gets PR details, diff, comments, and existing reviews
2. **Task Context Lookup**: Searches for task context matching the PR URL or branch
3. **Create Worktree**: Creates a detached-HEAD worktree at the PR's head (for `git grep`/`git show` access); fork PRs fall back to the source repo
4. **Run OpenCode**: Launches OpenCode with read-only `review` agent and injected context
5. **Analyze**: Agent reviews code against the original plan and intent
6. **Post Comment**: Agent posts review comment via `gh pr review`

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
├── tasks/                  # Persistent task contexts
│   └── <task-id>/
│       ├── task.json       # Task metadata and phase
│       ├── context.md      # Agent research notes
│       └── plan.md         # Implementation plan
└── docs/                   # Documentation
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `AID_DEBUG=1` | Enable debug output |
| `AID_DRY_RUN=1` | Show what would be done without executing |
| `AID_NO_CONTEXT=1` | Disable task context injection |

## License

MIT
