# MCP Portfolio Signal Reason Matrix - 2026-07-14

- Work order: `WO-PSC-1`
- Captured: `2026-07-14T16:26:51.103001Z`
- Accepted runtime source: `e938f0a0096772df5ea6f2d31931dc44ed86cc8c`
- Projected schema: `project_atlas.remote_project_inventory.v3`
- Projection semantics: WO-PSC-1 candidate source applied to the accepted runtime read; this is pre-activation evidence
- Scope: all operator-approved inventory aliases and labels; no local IDs, paths, notes, commands, or raw evidence
- Data action: read-only baseline; no bulk freshness or lifecycle cleanup was performed

## Summary

| Measure | Count |
|---|---:|
| Approved inventory | 49 |
| Planning action required | 28 |
| Planning action not required | 21 |
| Data refresh required | 48 |
| Data refresh not required | 1 |
| Freshness current | 2 |
| Freshness stale | 37 |
| Freshness unknown | 10 |
| Severity high | 2 |
| Severity medium | 33 |
| Severity low | 13 |
| Severity none | 1 |

## Matrix

`planningActionRequired` identifies project/workload decisions or blockers. `dataRefreshRequired` identifies evidence maintenance. `stale` and `unknown` remain distinct and are never bulk-cleared by this work order.

| Alias | Approved label | Lifecycle | Freshness | Planning | Data refresh | Severity | Sanitized reason classes |
|---|---|---|---|---|---|---|---|
| ali8e-v-1 | ali8e.v.1 | needs_review | stale | yes | yes | medium | freshness_stale, lifecycle, local_evidence |
| atlas-github-sync | atlas-github-sync | local_only | stale | yes | yes | medium | freshness_stale, lifecycle, local_evidence |
| bag-of-holding | Bag of Holding | active | current | yes | yes | high | local_evidence, workload |
| biological-simlab | Biological SimLab | needs_review | stale | yes | yes | medium | freshness_stale, lifecycle, local_evidence |
| ca-explorer | CA Explorer | needs_update | stale | yes | yes | medium | freshness_stale, lifecycle, local_evidence, remote_evidence |
| canon-system-math | Canon System - math | active | stale | yes | yes | medium | freshness_stale, local_evidence, remote_evidence, workload |
| clinical | Clinical | stale | unknown | yes | yes | medium | freshness_unknown, lifecycle, local_evidence |
| code-language-library | Code Language Library | needs_update | stale | yes | yes | medium | freshness_stale, lifecycle, local_evidence |
| codex-reanimator | codex-reanimator | needs_review | stale | yes | yes | medium | freshness_stale, lifecycle, local_evidence, remote_evidence |
| coheron-app | Coheron - app | needs_update | stale | yes | yes | medium | freshness_stale, lifecycle, local_evidence, remote_evidence |
| coheronia-game | Coheronia - game | active | stale | yes | yes | medium | freshness_stale, local_evidence, remote_evidence, workload |
| consultant-questions | Consultant_questions | active | unknown | no | yes | medium | freshness_unknown, local_evidence |
| daedric-classification-system-dcs | Daedric Classification System (DCS) | active | stale | no | yes | low | freshness_stale, local_evidence |
| daenary-security | daenary_Security | active | unknown | no | yes | medium | freshness_unknown, local_evidence |
| daily-substrate-stager-tool | Daily Substrate Stager Tool | local_only | stale | yes | yes | medium | freshness_stale, lifecycle, local_evidence |
| dev-launchpad | Dev Launchpad | active | stale | no | yes | low | freshness_stale, local_evidence, remote_evidence |
| governed-graph-substrate | Governed Graph Substrate | needs_review | stale | yes | yes | medium | freshness_stale, lifecycle, local_evidence, remote_evidence |
| graph-book | Graph Book | completed | stale | no | yes | low | freshness_stale, local_evidence |
| html2md-reanimator | HTML2MD Reanimator | completed | stale | no | yes | low | freshness_stale, local_evidence, remote_evidence |
| iteration-process | Iteration_Process | active | stale | no | yes | low | freshness_stale, local_evidence |
| llm-harness | LLM Harness | local_only | stale | yes | yes | medium | freshness_stale, lifecycle, local_evidence, workload |
| m8str0 | M8str0 | paused | stale | no | yes | low | freshness_stale, local_evidence, remote_evidence |
| mark-attie-farm | Mark_Attie_Farm | active | unknown | no | yes | medium | freshness_unknown, local_evidence |
| metis-head | Metis Head | active | stale | no | yes | low | freshness_stale, local_evidence, remote_evidence |
| mm-lake | MM_Lake | stale | stale | yes | yes | medium | freshness_stale, lifecycle, local_evidence |
| nurse-consultant-playbook | Nurse Consultant Playbook | active | unknown | no | yes | medium | freshness_unknown, local_evidence |
| obsidian-library | Obsidian Library | active | stale | yes | yes | medium | freshness_stale, local_evidence, remote_evidence, workload |
| openai-export-ingest | OpenAI Export Ingest | active | stale | yes | yes | medium | freshness_stale, local_evidence, workload |
| portfolio-item | Shopify Admin Catalog Sync | active | unknown | yes | yes | medium | freshness_unknown, local_evidence, workload |
| ppeck-me | ppeck.me | active | stale | yes | yes | high | freshness_stale, local_evidence, remote_evidence, workload |
| pre-industrialization | Pre_Industrialization | needs_update | stale | yes | yes | medium | freshness_stale, lifecycle, local_evidence |
| productivity-methods-atlas | productivity-methods-atlas | needs_review | stale | yes | yes | medium | freshness_stale, lifecycle, local_evidence, remote_evidence |
| project-atlas | Project Atlas | active | current | no | no | none | none |
| project-capsule | New Project Capsule Template | active | stale | yes | yes | medium | freshness_stale, local_evidence, workload |
| rct-protocol | RCT Protocol | active | unknown | no | yes | medium | freshness_unknown, local_evidence |
| reader-app | reader app | active | stale | no | yes | low | freshness_stale, local_evidence, remote_evidence |
| scm-lake | SCM_LAKE | needs_update | stale | yes | yes | medium | freshness_stale, lifecycle, local_evidence |
| sinternet-cult | Sinternet Cult | needs_update | unknown | yes | yes | medium | freshness_unknown, lifecycle, local_evidence, workload |
| societal-mapping | Societal_Mapping | active | stale | no | yes | low | freshness_stale, local_evidence |
| sot-lake | SOT_LAKE | needs_update | stale | yes | yes | medium | freshness_stale, lifecycle, local_evidence |
| space-nurse-platform | Space Nurse Platform | active | stale | no | yes | low | freshness_stale, local_evidence, remote_evidence |
| substrate-automaton | Substrate Automaton | stale | stale | yes | yes | medium | freshness_stale, lifecycle, local_evidence |
| substrate-of-coherent-systems | Substrate_of_Coherent_Systems | active | stale | no | yes | low | freshness_stale, local_evidence |
| telegram-bridge-gateway | Telegram Bridge Gateway | active | stale | no | yes | low | freshness_stale, local_evidence, remote_evidence |
| tomo-system | tomo-system | stale | stale | yes | yes | medium | freshness_stale, lifecycle, local_evidence, remote_evidence |
| trade-craft-card-library | trade_craft_card_library | active | stale | no | yes | low | freshness_stale, local_evidence |
| visual-post-it-notes-to-share-with-kristie | Visual post it notes to share with Kristie | active | unknown | no | yes | medium | freshness_unknown, local_evidence |
| wa-collective-bargaining | WA Collective Bargaining | completed | unknown | no | yes | medium | freshness_unknown, local_evidence |
| weather-clock | Weather Clock | stale | stale | yes | yes | medium | freshness_stale, lifecycle, local_evidence, remote_evidence |
