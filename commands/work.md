---
description: Execute full task workflow (explore, plan, implement, review, PR)
agent: dispatch
---

## Task

$ARGUMENTS

## Workflow

Execute this workflow autonomously:

1. **Explore**: Use @explore to find relevant files and understand the codebase
2. **Plan**: Use @general to create an implementation plan
3. **Implement**: Make code changes yourself, commit incrementally
4. **Review**: Use @reviewer to check your work
   - If NEEDS_FIXES → fix issues and re-review
   - Maximum 3 review cycles total
   - If PASS or max cycles reached → proceed to PR
5. **Create PR**: Push branch and create PR with `gh pr create`

After creating the PR, output the PR URL.

## Guidelines

- Do not ask for confirmation between steps
- Execute the entire workflow autonomously
- Only stop if genuinely blocked (ambiguous requirements, missing dependencies)
- If issues remain after 3 review cycles, note them in the PR description
