---
description: Review a pull request and post feedback (read-only)
agent: review
subtask: false
---

Review the pull request at: $ARGUMENTS

## Instructions

1. Fetch the PR details and diff using `gh pr view` and `gh pr diff`
2. Analyze the changes for code quality issues, bugs, and improvements
3. Post a review comment with your findings using `gh pr review`

## Review Format

Your comment should include:
- **Code Quality Issues**: Specific problems with file:line references
- **Improvement Suggestions**: Concrete ways to make the code better
- **Verdict**: Approve / Request Changes / Comment

If changes are needed, suggest: `aid <pr-url>`
If approved: `gh pr merge <number> --repo <owner/repo> --squash --delete-branch`
