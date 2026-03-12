---
description: Review a pull request and post feedback (read-only)
agent: review
subtask: false
---

Review PR: $ARGUMENTS

## Objective
Fetch the diff, analyze for issues, and post exactly ONE review comment.

## Process
1. **Fetch PR Details**: `gh pr view <number> --repo <owner/repo> --json title,body,files,additions,deletions`
2. **Fetch Diff**: `gh pr diff <number> --repo <owner/repo>`
3. **Analyze**: Check for bugs, security issues, error handling, and performance problems.
4. **Report**: Post a single review comment using `gh pr review`.

## Strict Constraints
- **Read-only**: Do not edit files or create commits.
- **Single Output**: Your ONLY output must be the `gh pr review` command.
- **No Chatter**: Do not add explanations before or after the command.
