# Variable Matrix

Secret policy: names only. Secret values must never be recorded.

| Name | Type | Location | Default | Required | Secret | Used By | Notes | Last Verified |
|---|---|---|---|---|---|---|---|---|
| project_id | string | `.project/project_manifest.json` | `project-atlas` | yes | no | Capsule, Atlas outbox, BOH packet | Stable project identifier. | 2026-07-01 |
| display_name | string | `.project/project_manifest.json` | `Project Atlas` | yes | no | Capsule, operator docs | Human-readable project name. | 2026-07-01 |
| root | path | `.project/project_manifest.json` | `.` | yes | no | Capsule doctor | Repo-local root. | 2026-07-01 |
| visibility | enum | `.project/project_manifest.json` | `public` | yes | no | Public safety policy | GitHub remote visibility is public. | 2026-07-01 |
| profiles | string array | `.project/project_manifest.json`, `.project/ops_capsule.json` | `public_repo`, `software_project` | yes | no | Capsule doctor | Matches public Flutter software repo. | 2026-07-01 |
| validation.required | string array | `.project/project_manifest.json` | analyze, test | yes | no | Verification loop | Required validation commands. | 2026-07-01 |
| atlas_sync | object | `.project/project_manifest.json` | outbox enabled | yes | no | Capsule sync | Creates local Atlas packet only. | 2026-07-01 |
| boh_sync | object | `.project/project_manifest.json` | outbox/evidence-only | yes | no | Capsule sync | No BOH promotion authority. | 2026-07-01 |
| git_policy | object | `.project/project_manifest.json` | manual push, no unrelated dirty | yes | no | Capsule closeout | Commit only after scoped/signable review. | 2026-07-01 |
| raw_run_ledger | local path | `.project/runs/` | local-only | yes | may contain local paths | Capsule evidence | Ignored in public repo. | 2026-07-01 |
| atlas_outbox | local path | `.project/atlas_outbox/` | local-only | yes | may contain local paths | Atlas sync queue | Ignored in public repo. | 2026-07-01 |
| boh_outbox | local path | `.project/boh_outbox/` | local-only | yes | may contain local paths | BOH sync queue | Ignored in public repo. | 2026-07-01 |
| detailed_app_variable_map | doc path | `VARIABLE_MAP.md` | existing app doc | yes | names only | App maintainers | Detailed app schema/data-flow map. | 2026-07-01 |
