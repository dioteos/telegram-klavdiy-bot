# Memory

Persistent cross-session knowledge. Loaded on every startup so Claude has context from previous conversations.

## Types

- **user** — who the user is: role, goals, preferences, language, stack
- **feedback** — how to work: corrections, confirmed approaches, behavior rules
- **project** — ongoing work: goals, decisions, status, deadlines (use absolute dates)
- **reference** — where to find things: external systems, URLs, dashboards

## File format

Each memory is a separate `.md` file with YAML frontmatter:

```
---
name: Short descriptive name
description: One-line summary — used to judge relevance
type: user | feedback | project | reference
updated: YYYY-MM-DD
---

Content. For feedback/project types, structure as:
Rule or fact.

**Why:** Reason or context.
**How to apply:** When and how this should shape behavior.
```

## Lifecycle

- **Create**: when learning something cross-session-useful. Check for duplicates first.
- **Update**: when information changes. Always update the `updated` date.
- **Delete**: when confirmed outdated or wrong.
- **Stale check**: if `updated` is older than 30 days — verify the memory is still accurate before acting on it.

## What NOT to save

- Code patterns or architecture derivable from reading the codebase
- Git history (use `git log`)
- Debugging solutions (the fix is in the code)
- Ephemeral task details only useful in the current session

## Bootstrap

If no memory files exist (fresh clone):
1. Ask user: name, role, language, what they're building
2. Create `user_profile.md` from answers
3. Note: more memories will accumulate naturally over conversations

## Skip rules

Skip `INSTRUCTIONS.md` (this file) when loading memories.
