---
name: dispatch-workflow
description: Development workflow for git worktrees - guides through understanding, planning, implementing, reviewing, and creating PRs
---

# Development Workflow

A skill for task completion in git worktrees. Use this skill when working on isolated tasks.

## Workflow Steps

### 1. Understand the Task
- Read the task description carefully
- Identify the scope and requirements
- Check for any referenced files, issues, or documentation

### 2. Explore the Codebase
- Understand the project structure
- Identify relevant files and patterns
- Look for existing tests and documentation

### 3. Plan the Implementation
- Break down the task into smaller steps
- Consider edge cases and error handling
- Plan for backward compatibility if needed

### 4. Implement Changes
- Make atomic, focused commits as you progress
- Follow existing code style and conventions
- Add or update tests for new functionality
- Update documentation if needed

### 5. Review
Before creating a PR, review your changes:
- Run the test suite if available (`npm test`, `go test`, `pytest`, etc.)
- Run linting/formatting tools if configured
- Check for debugging code left behind
- Verify commit messages follow conventional format

### 6. Create Pull Request
- Write a clear PR title summarizing the change
- Include a description with:
  - What was changed and why
  - How to test the changes
  - Any breaking changes or migration notes
  - Screenshots if UI changes
- Link to related issues

## Commit Message Format

Use conventional commits:
- `feat:` new feature
- `fix:` bug fix
- `docs:` documentation only
- `style:` formatting, no code change
- `refactor:` code change without feat/fix
- `test:` adding or updating tests
- `chore:` maintenance tasks

## Best Practices

1. **Atomic commits**: Each commit should be a single logical change
2. **Test coverage**: Add tests for new code paths
3. **Documentation**: Update docs for user-facing changes
4. **Error handling**: Handle edge cases gracefully
5. **Backward compatibility**: Avoid breaking existing APIs unless necessary

## Common Commands

```bash
# Check test runner
npm test          # Node.js
go test ./...     # Go
pytest            # Python
cargo test        # Rust

# Format code
npm run format    # or prettier
go fmt ./...
black .           # Python
cargo fmt         # Rust

# Lint code
npm run lint      # or eslint
golangci-lint run
flake8 / ruff     # Python
cargo clippy      # Rust

# Create PR
gh pr create --title "feat: description" --body "..."
```

## Troubleshooting

### Tests failing
1. Read the error message carefully
2. Check if tests passed before your changes
3. Run individual failing tests for faster iteration
4. Look for test fixtures or setup that may need updating

### Merge conflicts
1. Fetch latest changes: `git fetch origin main`
2. Rebase onto main: `git rebase origin/main`
3. Resolve conflicts in each file
4. Continue rebase: `git rebase --continue`

### CI failures
1. Check the CI logs for specific errors
2. Common issues: missing dependencies, env vars, test flakiness
3. Fix issues and push new commits
