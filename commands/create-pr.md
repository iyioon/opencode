---
description: Create a pull request for completed work
agent: dispatch
---

## Create Pull Request

### Step 1: Verify Clean State

Run `git status` to ensure all changes are committed.
If there are uncommitted changes, commit them first.

### Step 2: Push Branch

```bash
git push -u origin HEAD
```

### Step 3: Gather Context

```bash
# List commits
git log --oneline origin/main..HEAD

# Show diff stats
git diff --stat origin/main..HEAD
```

### Step 4: Create PR

Use `gh pr create` with a descriptive title and body:

```bash
gh pr create --title "<type>: <description>" --body "$(cat <<'EOF'
## Summary
<Brief description of what this PR accomplishes>

## Changes
- <List of specific changes>

## Testing
<How the changes were tested>

## Related Issues
<Closes #123 or N/A>
EOF
)"
```

**Title format**: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`

### Step 5: Output Result

Print the PR URL so the user can review it.
