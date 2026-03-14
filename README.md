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

## AI Workflow

The AI follows a structured **Plan → Implement → Review → Fix** cycle, orchestrated by the `dispatch` agent.

### Cycle
1.  **Understand (Plan):** The AI analyzes the task and explores the codebase.
    *   *Delegation:* Uses `@explore` agent if the relevant files are unknown or a broad search is needed.
2.  **Implement:** The AI writes code, creates files, and runs commands.
    *   *Strategy:* It works incrementally, committing after logical units of work.
3.  **Review:** Before finishing, the AI requests a self-review.
    *   *Delegation:* Delegates to `@reviewer` agent.
    *   *Reason:* The `@reviewer` is a separate, read-only agent with a strict prompt to find bugs, security issues, and incomplete implementation. This provides an objective "second pair of eyes" and prevents hallucinated correctness.
4.  **Fix:** If the reviewer returns `NEEDS_FIXES`, the `dispatch` agent addresses the issues and requests another review (up to 3 cycles).
5.  **Ship:** Once approved (`PASS`), the AI pushes changes and creates a Pull Request.

### Delegation Justification
*   **Dispatch Agent (`agents/dispatch.md`):** The general-purpose orchestrator. It maintains the overall task context and makes decisions. It delegates to specialized agents to keep its own context clean and focused on implementation.
*   **Explore Agent (`task: explore`):** Optimized for code navigation and search. Used to quickly locate relevant files without cluttering the main agent's context with search results.
*   **Reviewer Agent (`agents/reviewer.md`):** Optimized for critique. It has no write access, forcing it to be objective. Segregating review into a separate agent reduces bias, as the implementing agent is often biased towards its own code.

## Configuration

You can customize the AI's behavior by editing the configuration files in `~/.config/opencode`.

### Global Configuration (`opencode.json`)
Configure MCP servers, permissions, and environment variables.
*   **MCP Servers:** Add/remove tools like `context7` or `gh_grep`.
*   **Permissions:** Control file access and command execution.

### Agent Configuration (`agents/*.md`)
Customize agent behavior, models, and system prompts.
*   **Prompt:** Edit the text to change instructions or persona.
*   **Model:** Change `model: github-copilot/gemini-3-pro-preview` to other available models.
*   **Temperature:** Adjust creativity (lower for coding, higher for creative writing).
*   **Tools:** Enable/disable specific tools for an agent.

### Command Configuration (`commands/*.md`)
Define custom slash commands (e.g., `/work`, `/create-pr`).
*   Map commands to specific agents and provide initial instructions.

