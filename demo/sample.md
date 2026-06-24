# Project Atlas — Markdown Sample

This file demonstrates **Markdown** (`.md`) import in the Library.

When imported, the raw Markdown source is stored in the `rendered_markdown`
column. The Library preview renders it as formatted Markdown — headings,
bold, code blocks, and lists all display correctly.

---

## Project Status

| Area | Status | Owner |
|------|--------|-------|
| Backend | In progress | Alice |
| Frontend | Blocked | Bob |
| QA | Not started | Carol |

## Blockers

1. Vendor API credentials not yet provisioned
2. Staging environment DNS not resolving

## Next Actions

- [ ] Follow up with vendor on credentials (Alice, by Fri)
- [ ] Escalate DNS issue to infrastructure (Bob, urgent)
- [ ] Draft QA test plan for Phase 2 (Carol)

## Notes

> The migration window is narrow — coordinate with the infrastructure team
> before scheduling any deployment.

```bash
# Quick health check
curl -s http://localhost:11434/api/tags | jq '.models[].name'
```
