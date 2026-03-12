# Usage Guide

## Interactive Mode (TUI)

The simplest way to use aid is without any arguments - this opens the OpenCode TUI:

```bash
# Navigate to your project
cd /path/to/your/project

# Start interactive mode with OpenCode TUI
aid
```

This will:
1. Open OpenCode TUI immediately in your current repository
2. Present an initial prompt that guides you to describe your task
3. Wait for you to type your task description directly in the OpenCode interface
4. Provide full visual interface with real-time updates
5. Work on the task once you provide details

### Benefits of Interactive Mode

- **Visual Interface**: Full OpenCode TUI with syntax highlighting and real-time updates
- **No setup needed**: Works directly in your current repository
- **Guided experience**: Clear instructions on how to describe your task
- **Real-time feedback**: Watch progress as the AI works
- **Simple workflow**: Just run `aid` and start describing what you want

## Direct Mode (Background)

For predefined tasks, you can run aid with arguments to execute in background mode:

```bash
# Work on a GitHub issue (background execution)
aid https://github.com/user/repo/issues/123

# Work on a plain text task (background execution)
aid "Add dark mode toggle to settings page"
```

This will:
1. Create an isolated worktree for the task
2. Run OpenCode in non-TUI mode with minimal output
3. Execute the task autonomously in the background
4. Clean up when complete

### Benefits of Direct Mode

- **No interruption**: Runs in background without taking over your terminal
- **Isolation**: Uses worktrees to avoid affecting your current work
- **Autonomous**: Requires no interaction once started
- **Minimal output**: Suppresses most OpenCode output for clean execution

## Task Mode

## Basic Usage

### Working on a GitHub Issue

```bash
# Navigate to your project
cd /path/to/your/project

# Dispatch with a GitHub issue URL
aid https://github.com/owner/repo/issues/123
```

The agent will:
1. Fetch the issue title and description
2. Create a branch named `ai/issue-123`
3. Set up a worktree in `~/.config/opencode/worktrees/ai-issue-123`
4. Work on the task autonomously
5. Create commits as it progresses
6. Self-review the changes
7. Create a PR against the main branch

### Working on a Plain Text Task

```bash
# Describe what you want done
aid "Add a dark mode toggle to the settings page"

# More detailed descriptions work better
aid "Refactor the user authentication module to use JWT tokens instead of session cookies. Update all related tests."
```

## Managing Sessions

### List Active Sessions

```bash
aid list
```

Output:
```
Active AI Dispatch Sessions
───────────────────────────────────────────────────────────────────────────────────────
SESSION              STATUS       BRANCH                              CREATED
───────────────────────────────────────────────────────────────────────────────────────
20250312-143022-1234 running      ai/issue-123                        2025-03-12T14:30:22Z
20250312-150145-5678 completed    ai/task-add-dark-mode-150145        2025-03-12T15:01:45Z
───────────────────────────────────────────────────────────────────────────────────────
Total: 2 session(s)
```

### Resume a Session

If you need to continue work on a previous session:

```bash
aid resume 20250312-143022-1234
```

This opens OpenCode in the existing worktree with conversation history.

### Clean Up Orphaned Sessions

If sessions weren't cleaned up properly (e.g., system crash):

```bash
# See orphaned sessions
aid cleanup

# Force cleanup
aid cleanup --force
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `AID_DEBUG=1` | Enable verbose debug output |
| `AID_DRY_RUN=1` | Show what would happen without executing |

Example:
```bash
AID_DEBUG=1 aid "Add feature X"
```

## Workflow Details

### What Happens During Dispatch

1. **Input Parsing**
   - Detects if input is a GitHub URL or plain text
   - For GitHub issues, fetches title, body, and labels via `gh` CLI

2. **Branch Creation**
   - GitHub issues: `ai/issue-<number>`
   - Plain text: `ai/task-<sanitized-description>-<timestamp>`

3. **Worktree Setup**
   - Creates worktree in `~/.config/opencode/worktrees/`
   - Based on latest `origin/main` (or `origin/master`)

4. **State Tracking**
   - Creates JSON state file in `~/.config/opencode/dispatch/`
   - Tracks session ID, branch, worktree path, status

5. **OpenCode Execution**
   - Runs `opencode run --agent dispatch` with task prompt
   - Agent works autonomously through the task

6. **Cleanup**
   - On exit (normal or interrupted), removes worktree
   - Deletes branch if it wasn't pushed
   - Updates/removes state file

### The Dispatch Agent

The dispatch agent is configured for autonomous work:
- Full edit permissions (no approval prompts)
- Full bash access including git and gh commands
- Temperature set to 0.3 for consistent behavior

It follows a structured workflow:
1. Understand the task
2. Plan the implementation
3. Implement incrementally with commits
4. Self-review all changes
5. Create a PR

## Tips for Better Results

### Choose the Right Mode

```bash
# Use interactive mode (TUI) for:
# - Exploratory tasks where you're not sure what you need
# - When you want guided assistance and real-time visual feedback
# - Quick one-off tasks where you want to watch progress
# - Learning or debugging scenarios
aid

# Use direct mode (background) for:
# - Well-defined tasks you can describe upfront
# - GitHub issues with detailed requirements  
# - Tasks that benefit from isolated worktrees
# - When you want to continue other work while AI executes
aid "Specific task description"
aid https://github.com/owner/repo/issues/123
```

### Write Clear Task Descriptions

```bash
# Good - specific and actionable
aid "Add input validation to the user registration form. Validate email format, password strength (min 8 chars, 1 uppercase, 1 number), and username uniqueness."

# Less ideal - vague
aid "Fix the form"
```

### Provide Context

For complex tasks, include relevant context:

```bash
aid "Implement rate limiting for the API endpoints. Use Redis for storage. Follow the pattern established in src/middleware/auth.ts. Limit to 100 requests per minute per IP."
```

### Use GitHub Issues for Complex Tasks

GitHub issues allow for:
- Detailed descriptions with markdown
- Labels for categorization
- Comments for additional context
- Automatic linking in the PR
