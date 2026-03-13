---
description: Execute full task workflow (explore, plan, implement, review, PR)
agent: dispatch
---

<task>
$ARGUMENTS
</task>

<workflow>
Execute this workflow autonomously:

1. **Understand**: Read relevant files (directly if you know where, via @explore if not)
2. **Plan & Implement**: Make code changes yourself, commit incrementally
3. **Review**: Use @reviewer to check your work
   - If NEEDS_FIXES → fix issues and re-review (max 3 cycles)
   - If PASS → proceed to PR
4. **Create PR**: Push branch and create PR with `gh pr create`

After creating the PR, output the PR URL.
</workflow>

<guidelines>
- **Implement the code yourself** - you are the implementer, not an advisor
- Do not ask for confirmation between steps
- Execute the entire workflow autonomously
- Only stop if genuinely blocked (ambiguous requirements, missing dependencies)
- Use subagents strategically, not by default (see dispatch.md for guidance)
- If issues remain after 3 review cycles, note them in the PR description
</guidelines>
