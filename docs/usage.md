# Usage Guide

## TUI Mode

All `aid` commands run in TUI mode, providing a visual interface for all operations:

```bash
# Navigate to your project
cd /path/to/your/project

# Interactive mode - opens TUI with guided prompts
aid

# Work on a GitHub issue (TUI mode)
aid https://github.com/user/repo/issues/123

# Work on a plain text task (TUI mode)
aid "Add dark mode toggle to settings page"
```

This will:
1. Create an isolated worktree for the task
2. Open OpenCode TUI with full visual interface
3. Present an initial prompt that guides you through the task
4. Provide real-time updates as the AI works
5. Work on the task interactively

### Benefits of TUI Mode

- **Visual Interface**: Full OpenCode TUI with syntax highlighting and real-time updates
- **Guided experience**: Clear instructions and interactive prompts
- **Real-time feedback**: Watch progress as the AI works
- **Worktree isolation**: Each task runs in its own isolated worktree
- **Interactive workflow**: Engage with the AI during the process

## Basic Usage

### Working on a GitHub Issue

```bash
# Navigate to your project
cd /path/to/your/project

# Start working on a GitHub issue
aid https://github.com/owner/repo/issues/123
```

The tool will:
1. Fetch the issue title and description
2. Create a unique session ID (e.g., `20250312-143022-1234`)
3. Create a branch named `aid/20250312-143022-1234`
4. Set up a worktree in `~/.config/opencode/worktrees/20250312-143022-1234`
5. Work on the task automatically
6. Create commits as it progresses
7. Review the changes
8. Create a PR against the main branch

### Working on a GitHub PR

```bash
# Work on an existing PR (implement requested changes)
aid https://github.com/owner/repo/pull/456
```

The agent will:
1. Fetch the PR details and review comments
2. Create a branch named `aid/20250312-143022-5678` (using a unique session ID)
3. Implement the requested changes
4. Push commits to a new session branch (`aid/<session-id>`) referencing the original PR

### Working on a Plain Text Task

```bash
# Describe what you want done
aid "Add a dark mode toggle to the settings page"

# More detailed descriptions work better
aid "Refactor the user authentication module to use JWT tokens instead of session cookies. Update all related tests."
```

---

## PR Review Workflow

The `aid review` command enables a **human-in-the-loop** workflow for reviewing AI-generated (or any) pull requests. This is the recommended way to quality-check work before merging.

### Quick Start

```bash
# Review a PR (read-only, posts comment)
aid review https://github.com/owner/repo/pull/123
```

### How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│  Step 1: AI creates PR (or human opens PR)                      │
│  └─> PR opened: https://github.com/owner/repo/pull/42          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Step 2: Run review                                             │
│  $ aid review https://github.com/owner/repo/pull/42            │
│                                                                 │
│  The review agent:                                              │
│  • Fetches PR diff, description, and existing comments          │
│  • Analyzes code for bugs, quality issues, improvements         │
│  • Posts a structured review comment to the PR                  │
│  • Does NOT edit any files or create commits                    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Step 3: Review the feedback                                    │
│                                                                 │
│  The posted comment includes:                                   │
│  • Code quality issues (with file:line references)              │
│  • Improvement suggestions                                      │
│  • Verdict: Approve / Request Changes / Comment                 │
└─────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
     ┌────────────────┐              ┌────────────────┐
     │ Verdict:       │              │ Verdict:       │
     │ Approve        │              │ Request Changes│
     └───────┬────────┘              └───────┬────────┘
             │                               │
             ▼                               ▼
     ┌────────────────┐              ┌────────────────┐
     │ Merge PR with: │              │ Run:           │
     │ gh pr merge    │              │ aid <pr-url>   │
     │ --delete-branch│              │ to fix issues  │
     └────────────────┘              │                │
                                     └───────┬────────┘
                                             │
                                             ▼
                                     ┌────────────────┐
                                     │ AI implements  │
                                     │ fixes, pushes  │
                                     │ new commits    │
                                     └───────┬────────┘
                                             │
                                             ▼
                                     ┌────────────────┐
                                     │ Run review     │
                                     │ again to       │
                                     │ verify fixes   │
                                     └────────────────┘
```

### Review vs Dispatch: Key Differences

| Aspect | `aid review <pr-url>` | `aid <pr-url>` |
|--------|----------------------|----------------|
| **Mode** | Read-only | Full access |
| **Creates worktree** | No | Yes |
| **Edits files** | No | Yes |
| **Creates commits** | No | Yes |
| **Posts PR comment** | Yes | No (creates commits) |
| **Agent used** | `review` | `dispatch` |
| **Use case** | Quality check | Implement changes |

### What the Review Comment Includes

The AI posts a structured review comment like this:

```markdown
## Code Review

### Code Quality Issues
- [ ] **src/api/handler.ts:42** - Missing error handling for null response
- [ ] **src/utils/validate.ts:15** - Regex pattern may cause ReDoS vulnerability

### Improvement Suggestions
- Consider using `optional chaining` in `getUserData()` for cleaner null checks
- The retry logic could be extracted to a reusable utility function

### Verdict: **Request Changes**

> To address these issues, run:
> ```
> aid https://github.com/owner/repo/pull/42
> ```
```

### Merge Policy

PRs are merged manually using `gh pr merge --delete-branch`. This ensures:

1. A human reviews every AI-generated PR
2. You maintain control over what gets merged
3. The AI's work is validated before production
4. Branches are automatically cleaned up after merge

### Example: Full Workflow

```bash
# 1. AI works on an issue and creates a PR
aid https://github.com/myorg/myrepo/issues/99
# → AI creates PR #100

# 2. Review the AI's PR
aid review https://github.com/myorg/myrepo/pull/100
# → AI posts review comment with findings

# 3a. If approved: merge and delete branch
gh pr merge 100 --repo myorg/myrepo --squash --delete-branch

# 3b. If changes needed: dispatch work on the PR
aid https://github.com/myorg/myrepo/pull/100
# → AI fixes the issues and pushes new commits

# 4. Review again
aid review https://github.com/myorg/myrepo/pull/100
# → Verify fixes, then merge with: gh pr merge --squash --delete-branch
```

### Using Review in the TUI

You can also review PRs interactively in OpenCode's TUI:

```bash
# Start OpenCode
opencode

# Use the review-pr command
/review-pr https://github.com/owner/repo/pull/123
```

Or switch to the review agent and ask directly:
1. Press **Tab** to cycle to the `review` agent
2. Paste the PR URL and ask for a review

---

## Managing Sessions

### List Active Sessions

```bash
aid list
```

Output:
```
Active Development Sessions
───────────────────────────────────────────────────────────────────────────────────────
SESSION              STATUS       BRANCH                              CREATED
───────────────────────────────────────────────────────────────────────────────────────
20250312-143022-1234 running      aid/20250312-143022-1234            2025-03-12T14:30:22Z
20250312-150145-5678 completed    aid/20250312-150145-5678            2025-03-12T15:01:45Z
───────────────────────────────────────────────────────────────────────────────────────
Total: 2 session(s)
```

### Resume a Session

If you need to continue work on a previous session:

```bash
aid resume 20250312-143022-1234
```

This opens OpenCode in the existing worktree with conversation history.

### View Session Details

To inspect a session's metadata, commits, and PR status:

```bash
aid view 20250312-143022-1234
```

Output:
```
Session: 20250312-143022-1234
─────────────────────────────────────────────
Status:        running
Created:       2025-03-12T14:30:22Z
Type:          github_issue
Branch:        aid/20250312-143022-1234
Worktree:      /Users/you/.config/opencode/worktrees/20250312-143022-1234

Task Description
─────────────────────────────────────────────
GitHub Issue #123: Fix login button on mobile

Recent Commits
─────────────────────────────────────────────
abc1234 feat: add touch event handler
def5678 fix: increase tap target size

Pull Request
─────────────────────────────────────────────
  #124 - Fix login button on mobile (open)
  https://github.com/owner/repo/pull/124

Open session in OpenCode? [y/N]
```

### Clean Up Orphaned Sessions

If sessions weren't cleaned up properly (e.g., system crash):

```bash
# See orphaned sessions
aid cleanup

# Force cleanup
aid cleanup --force
```

### Clean Up Stale Branches

After merging PRs, remote branches are deleted but local tracking references may remain. To clean them up:

```bash
git fetch --prune
```

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `AID_DEBUG=1` | Enable verbose debug output |
| `AID_DRY_RUN=1` | Show what would happen without executing |

Example:
```bash
AID_DEBUG=1 aid review https://github.com/owner/repo/pull/123
```

---

## Workflow Details

### What Happens During Execution

1. **Input Parsing**
   - Detects if input is a GitHub issue/PR URL or plain text
   - For GitHub issues/PRs, fetches details via `gh` CLI

2. **Branch Creation**
   - Uses a unique session ID for branch naming
   - Format: `aid/<timestamp>-<pid>`
   - Example: `aid/20250312-143022-1234`

3. **Worktree Setup**
   - Creates worktree in `~/.config/opencode/worktrees/<session-id>`
   - Based on latest `origin/main` (or `origin/master`)

4. **State Tracking**
   - Creates JSON state file in `~/.config/opencode/dispatch/`
   - Tracks session ID, branch, worktree path, status

5. **OpenCode Execution**
   - Runs `opencode --agent dispatch` with task description
   - Follows structured development workflow

6. **Cleanup**
   - On exit (normal or interrupted), removes worktree
   - Deletes branch if it wasn't pushed
   - Updates/removes state file

### What Happens During Review

1. **PR Fetching**
   - Fetches PR metadata (title, description, author)
   - Retrieves full diff via `gh pr diff`
   - Loads existing comments and reviews for context

2. **OpenCode Execution**
   - Runs `opencode --agent review` with PR context
   - Agent analyzes in read-only mode (cannot edit files)

3. **Review Posting**
   - Agent posts structured comment via `gh pr review`
   - No worktree created, no cleanup needed

### The Development Agent

The development agent is configured for automated work:
- Full edit permissions (no approval prompts)
- Full bash access including git and gh commands
- Temperature set to 0.3 for consistent behavior

It follows a structured workflow:
1. Understand the task
2. Plan the implementation
3. Implement incrementally with commits
4. Review all changes
5. Create a pull request

### The Review Agent

The review agent is configured for read-only analysis:
- All edit tools disabled (write, edit, patch, multiedit)
- Bash restricted to read-only commands (git diff, git log, gh pr)
- Temperature set to 0.3 for consistent behavior

It focuses on:
1. Understanding the PR context
2. Analyzing code quality
3. Posting constructive feedback

---

## Tips for Better Results

### Choose the Right Mode

```bash
# TUI Mode is great for:
# - Interactive tasks where you want to watch progress
# - When you want real-time visual feedback
# - Quick tasks where you want immediate visibility
# - Learning or debugging scenarios
aid
aid "Add dark mode toggle"
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

### Review Iteratively

For large PRs, you may want to:
1. Run `aid review` to get initial feedback
2. Have the AI fix critical issues with `aid <pr-url>`
3. Run `aid review` again to verify
4. Repeat until the verdict is "Approve"
5. Merge with `gh pr merge --squash --delete-branch`
