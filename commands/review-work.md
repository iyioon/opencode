---
description: Review all changes before creating a pull request
agent: dispatch
subtask: false
---

## Review Checklist

Review all your changes thoroughly before creating a PR.

### 1. View All Changes
Run `git diff HEAD~$(git rev-list --count HEAD ^origin/HEAD 2>/dev/null || echo 1)` to see all changes.

### 2. Code Quality Review
- [ ] Code is clean and readable
- [ ] No debug statements or commented code left behind
- [ ] Error handling is appropriate
- [ ] No hardcoded values that should be configurable
- [ ] Functions/methods are focused and not too long

### 3. Consistency Check
- [ ] Code follows existing patterns in the codebase
- [ ] Naming conventions match the project style
- [ ] File organization is logical

### 4. Functionality Check
- [ ] All requirements from the task are addressed
- [ ] Edge cases are handled
- [ ] No obvious bugs or issues

### 5. Testing Consideration
- [ ] Existing tests still pass (run test suite if available)
- [ ] New functionality has tests (if test framework exists)

### 6. Documentation
- [ ] Code comments where necessary
- [ ] README updates if needed
- [ ] API documentation if applicable

## Actions

If you find issues during review:
1. Fix them immediately
2. Create additional commits for fixes
3. Re-run this review

When satisfied with the review, run `/create-pr` to create the pull request.
