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
aid status                               # List tasks
aid view <task-id>                       # Open PR in browser
aid <task-id>                            # Address feedback or conflicts (auto-merges if approved)
aid approve <task-id>                    # Manually merge and cleanup
aid remove <task-id>                     # Remove a task (use --force for open PRs)
aid cleanup                              # Remove merged tasks
```

## Workflow

```
aid new "task" → AI works → PR created → Human reviews → aid <id> (auto-merge)
```

1. `aid new` creates a worktree and launches OpenCode
2. AI explores → plans → implements → requests review → creates PR
3. **Human Review:**
   - Run `aid view <task-id>` to open the PR on GitHub.
   - **Leave Feedback:** Comment on specific lines or submit a review requesting changes.
   - **Approve:** Submit an approval review or comment "LGTM" (which triggers auto-merge).
4. **Resume (`aid <task-id>`):**
   - **Fixes:** If there is feedback (changes requested or comments), the AI fetches your comments, plans a fix, implements it, and pushes updates.
   - **Merge:** If you approved or commented "LGTM", the tool automatically merges the PR and cleans up the task (deletes local worktree and branch).
5. `aid approve <task-id>` to manually merge if needed

## How Feedback Works

When you run `aid <task-id>` on a task with requested changes:
1. The tool fetches all comments and review threads from the GitHub PR using the `gh` CLI.
2. It detects if there are any merge conflicts with the base branch.
3. It passes this feedback (comments, reviews, conflict alerts) to the AI agent as a new prompt.
4. The AI implements the requested fixes and pushes to the same branch.
5. You review the updates on GitHub and repeat the cycle until approved.

## Recommended Workflow

1. **Start a task:** Run `aid new "description"` to create a new task in a clean worktree. The AI will begin coding immediately.
2. **Let the AI work:** The AI explores, implements, reviews its own code, and creates a pull request autonomously.
3. **Refine interactively:** Keep the OpenCode session open and continue to iterate with the AI in real time. You can ask follow-up questions, request changes, or guide the implementation.
4. **Step away when needed:** If you need to close the terminal or work on something else, the task persists. The worktree and PR remain until merged. You can:
   - Leave comments on the PR through GitHub.
   - Run `aid <task-id>` later to resume. The AI picks up your PR comments and continues. (Note: resuming starts a fresh AI context, so prior conversational context is lost.)
5. **Review and merge:** Once satisfied, approve the PR on GitHub and run `aid <task-id>` to auto-merge, or use `aid approve <task-id>`.

> **Tip:** Use [tmux](https://github.com/tmux/tmux) to run `aid` in a background pane. This lets you keep tasks running while you work on other things in separate tabs.

## Statuses

| Status | Meaning |
|--------|---------|
| `working` | AI is actively working |
| `awaiting-review` | PR created, waiting for human |
| `needs-changes` | Human requested changes |
| `ready-to-merge` | PR approved or LGTM |

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

## AI Workflow

The AI follows a structured **Understand → Implement → Review → Fix** cycle, orchestrated by the `dispatch` agent.

### Cycle
1.  **Understand:** The AI analyzes the task and explores the codebase.
    *   *Delegation:* Uses the built-in `@explore` agent if the relevant files are unknown or a broad search is needed.
2.  **Implement:** The AI writes code, creates files, and runs commands.
    *   *Strategy:* It works incrementally, committing after logical units of work.
3. **Review:** Before finishing, the AI requests a code review.
    *   *Delegation:* Delegates to `@reviewer` agent.
    *   *Reason:* The `@reviewer` is a separate, read-only agent with a strict prompt to find bugs, security issues, and incomplete implementation. This provides an objective "second pair of eyes" and prevents hallucinated correctness.
4.  **Fix:** If the reviewer returns `NEEDS_FIXES`, the `dispatch` agent addresses the issues and requests another review (up to 3 cycles).
5.  **Ship:** Once approved (`PASS`), the AI pushes changes and creates a Pull Request.

### Delegation Justification
*   **Dispatch Agent (`agents/dispatch.md`):** The general-purpose orchestrator. It maintains the overall task context and makes decisions. It delegates to specialized agents to keep its own context clean and focused on implementation.
*   **Explore Agent (built-in):** Optimized for code navigation and search. Used to quickly locate relevant files without cluttering the main agent's context with search results.
*   **Reviewer Agent (`agents/reviewer.md`):** Optimized for critique. It has no write access, forcing it to be objective. Segregating review into a separate agent reduces bias, as the implementing agent is often biased towards its own code.

## Configuration

You can customize the AI's behavior by editing the configuration files in `~/.config/opencode`.

### Global Configuration (`opencode.json`)
Configure MCP servers, global permissions, and environment variables.
*   **MCP Servers:** Add/remove tools like `context7` or `gh_grep`.
*   **Global Permissions:** Control access to external directories (e.g., `~/.config/opencode/worktrees/**`).

### Agent Configuration (`agents/*.md`)
Customize agent behavior, models, permissions, and system prompts.
*   **Prompt:** Edit the text to change instructions or persona.
*   **Model:** Change the model for each agent (e.g., `dispatch` uses `gemini-3-pro-preview`, `reviewer` uses `claude-sonnet-4.6`).
*   **Temperature:** Adjust creativity (lower for coding, higher for creative writing).
*   **Permissions:** Control file access (`edit: allow`) and command execution (`bash: ...`) for each agent.
*   **Tools:** Enable/disable specific tools for an agent.

### Command Configuration (`commands/*.md`)
Define custom slash commands (e.g., `/work`, `/create-pr`).
*   Map commands to specific agents and provide initial instructions.

## License

MIT

