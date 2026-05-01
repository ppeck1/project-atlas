# Project Atlas — Variable & Data Flow Map

> Auto-updated on each release. Describes every significant piece of state,
> where it lives, who writes it, and who reads it.

---

## 1. Database Tables

### `projects`
| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PK | Timestamp: `microsecondsSinceEpoch.toString()` |
| `title` | TEXT | User-provided project name |
| `owner` | TEXT? | Optional owner name |
| `created_at` | INTEGER | Unix ms |

**Written by:** `AppDb.createProject()`  
**Read by:** `watchProjects()`, `watchActiveProject()`, `ProjectsScreen`, `DashboardScreen`, Ollama summarizer

---

### `app_meta`
Key-value store for all settings and active state.

| Key pattern | Value | Written by | Read by |
|-------------|-------|-----------|---------|
| `active_project_id` | project ID | `setActiveProjectId()` | `watchActiveProject()`, router gate |
| `active_stage_id::{projectId}` | stage ID | `setActiveStageIdForProject()` | `watchActiveStageForProject()` |
| `is_bottleneck::{stageId}` | `'1'` or `'0'` | `setIsBottleneck()` | `GovernanceScreen` |
| `setting::telegram_bot_token` | bot token string | `SettingsScreen` → `setSetting()` | `sendTodayToTelegram()` |
| `setting::telegram_chat_id` | chat ID string | `SettingsScreen` → `setSetting()` | `sendTodayToTelegram()` |
| `setting::telegram_enabled` | `'1'` or `'0'` | `SettingsScreen` | currently informational |
| `setting::ollama_host` | URL string | `SettingsScreen` → `setSetting()` | `_buildOllama()` in `AppState` |
| `setting::ollama_model` | model name | `SettingsScreen` → `setSetting()` | `_buildOllama()` in `AppState` |

**AppDb constants:** `AppDb.kTelegramBotToken`, `AppDb.kTelegramChatId`, `AppDb.kTelegramEnabled`, `AppDb.kOllamaHost`, `AppDb.kOllamaModel`

---

### `stages`
| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PK | `{projectId}_stage_{n}` for auto-created stages |
| `project_id` | TEXT | FK → `projects.id` |
| `title` | TEXT | Stage name (e.g. "Build") |
| `owner` | TEXT? | Stage bottleneck owner (governance) |
| `position` | INTEGER | Display order (ascending) |
| `created_at` | INTEGER | |

**Written by:** `_ensureDefaultStages()` (auto), `setBottleneckOwner()` (governance)  
**Read by:** `watchStagesForProject()`, `WorkScreen`, `GovernanceScreen`, `TodayScreen` (via project label lookup)

---

### `work_items`
| Column | Type | Default | Notes |
|--------|------|---------|-------|
| `id` | TEXT PK | | `millisecondsSinceEpoch.toString()` |
| `stage_id` | TEXT | | FK → `stages.id` |
| `title` | TEXT | | Required |
| `description` | TEXT? | null | Optional detail text |
| `owner` | TEXT? | null | Who is responsible |
| `status` | TEXT | `'next'` | `inbox\|next\|doing\|waiting\|done\|archived` |
| `priority` | TEXT | `'normal'` | `low\|normal\|high\|urgent` |
| `due_at` | INTEGER? | null | Unix ms |
| `updated_at` | INTEGER | now | Set on every write |
| `created_at` | INTEGER | | Set on insert |
| `blocked_reason` | TEXT? | null | Non-null = blocked |
| `source` | TEXT? | null | Where the task came from |
| `phone_queue` | INTEGER | `0` | Bool: appears in Today phone section |
| `completed` | INTEGER | `0` | Bool: kept for backwards compat; `status='done'` is canonical |

**Written by:** `addWorkItem()`, `updateWorkItem()`, `setWorkItemStatus()`, `toggleWorkDone()`  
**Read by:** `WorkScreen`, `TodayScreen`, `ReviewScreen`, `ExportScreen`, Ollama summarizers, Telegram formatter

**Today query criteria** (any one triggers inclusion):
- `status = 'doing'`
- `phone_queue = 1`
- `priority IN ('high', 'urgent')`
- `due_at <= end of today`
- AND `status NOT IN ('done', 'archived')`

---

### `drafts`
| Column | Type | Default | Notes |
|--------|------|---------|-------|
| `id` | TEXT PK | | |
| `project_id` | TEXT? | null | Linked project (optional) |
| `work_item_id` | TEXT? | null | Linked task (optional) |
| `kind` | TEXT | | `project_summary\|today_summary\|email_draft\|task_extract\|custom` |
| `title` | TEXT | | Display title |
| `body` | TEXT | | Full AI output text |
| `created_at` | INTEGER | | |
| `updated_at` | INTEGER | | |
| `accepted` | INTEGER | `0` | Reserved — user approval flag |

**Written by:** `saveDraft()` — only after explicit user "Save Draft" action  
**Read by:** `watchDrafts()` — planned Drafts screen (not yet routed)

---

### `daily_reviews`
| Column | Type | Notes |
|--------|------|-------|
| `id` | TEXT PK | |
| `review_date` | INTEGER | Midnight of the review day |
| `summary` | TEXT | Markdown text |
| `created_at` | INTEGER | |

**Written by:** `saveDailyReview()` — triggered manually in ReviewScreen  
**Read by:** `getTodayReview()` — to check if today's review already exists

---

### `outbox_messages`
| Column | Type | Default | Notes |
|--------|------|---------|-------|
| `id` | TEXT PK | | |
| `channel` | TEXT | | Currently always `'telegram'` |
| `title` | TEXT | | Human label |
| `body` | TEXT | | Full message sent |
| `sent_at` | INTEGER? | null | Set on success |
| `created_at` | INTEGER | | |
| `status` | TEXT | `'pending'` | `pending\|sent\|failed` |
| `error` | TEXT? | null | Error message on failure |

**Written by:** `addOutboxMessage()` (pending), `markOutboxSent()`, `markOutboxFailed()`  
**Read by:** `watchOutboxMessages()` → `ExportScreen` outbox log

---

## 2. AppState (ChangeNotifier)

Located at `lib/shared/models/app_state.dart`. Wraps `AppDb` and adds:

| Field | Type | Notes |
|-------|------|-------|
| `db` | `AppDb` | Direct DB access (public — avoid using outside AppState) |
| `_activeProject` | `Project?` | Cached from stream subscription |
| `activeProject` | `Project?` getter | Synchronous read |
| `hasActiveProject` | `ValueNotifier<bool>` | Router uses this for nav gating |

**Exposed streams:**
- `watchProjects()` → `Stream<List<Project>>`
- `watchActiveProject()` → `Stream<Project?>`
- `watchStagesForProject(id)` → `Stream<List<Stage>>`
- `watchActiveStageForProject(id)` → `Stream<Stage?>`
- `watchWorkItemsForStage(id)` → `Stream<List<WorkItem>>`
- `watchTodayItems()` → `Stream<List<WorkItem>>`
- `watchDrafts()` → `Stream<List<Draft>>`
- `watchSetting(key)` → `Stream<String?>`
- `watchWorkOwner(id)` → `Stream<String?>`
- `watchBottleneckOwner(id)` → `Stream<String?>`
- `watchIsBottleneck(id)` → `Stream<bool>`

---

## 3. Services

### OllamaService (`lib/services/ollama_service.dart`)

| Field | Source | Default |
|-------|--------|---------|
| `host` | `AppDb.kOllamaHost` from AppMeta | `http://localhost:11434` |
| `model` | `AppDb.kOllamaModel` from AppMeta | `mistral` |

| Method | Input | Output |
|--------|-------|--------|
| `isAvailable()` | — | `bool` |
| `summarizeProject(...)` | project title, active/blocked/done lists | `OllamaResult` |
| `summarizeToday(...)` | doing/overdue/dueToday/blocked lists | `OllamaResult` |
| `draftEmail(...)` | task context + instruction | `OllamaResult` |
| `extractTasksFromNote(...)` | raw text, project title | `OllamaResult` |

**`OllamaResult`:** `{ input: String, output: String?, kind: String, title: String }`  
`output == null` means unavailable or empty response. Never auto-applied — always shown to user first.

---

### TelegramService (`lib/services/telegram_service.dart`)

| Field | Source |
|-------|--------|
| `botToken` | `AppDb.kTelegramBotToken` from AppMeta |
| `chatId` | `AppDb.kTelegramChatId` from AppMeta |

| Method | Notes |
|--------|-------|
| `sendMessage(text)` | Posts to `api.telegram.org/bot{token}/sendMessage` |
| `testConnection()` | Sends a test message |
| `formatTodayList(...)` | Static — builds escaped HTML message |

**HTML escaping:** All user content (titles, reasons, project names) is escaped via `_esc()` before insertion into the Telegram HTML message. Escapes `&`, `<`, `>`.

---

## 4. Navigation

Router: `lib/app/router.dart` using `go_router`  
Shell: `lib/shared/widgets/atlas_shell.dart`

| Route | Screen | Requires project? |
|-------|--------|------------------|
| `/projects` | `ProjectsScreen` | No |
| `/` | `DashboardScreen` | Yes |
| `/today` | `TodayScreen` | Yes |
| `/work` | `WorkScreen` | Yes |
| `/governance` | `GovernanceScreen` | Yes |
| `/review` | `ReviewScreen` | Yes |
| `/export` | `ExportScreen` | Yes |
| `/settings` | `SettingsScreen` | Yes |

**Gate logic:** If `hasActiveProject == false` and current route is not `/projects`, `AtlasShell` redirects to `/projects` via `addPostFrameCallback`.

---

## 5. Data Flows

### Project Creation
```
ProjectsScreen → showCreateProjectDialog()
  → AppState.createProject(title)
    → AppDb.createProject(id, title, now)
      → INSERT INTO projects
      → _ensureDefaultStages(id)   ← creates 6 stages
      → setActiveProjectId(id)     ← writes app_meta
    → notifyListeners()
  → watchActiveProject() fires → hasActiveProject = true → nav unlocks
```

### Task Creation (Work screen)
```
WorkScreen → showCreateWorkItemDialog()
  → returns Map { title, description, owner, status, priority, dueAt(ISO string) }
  → DateTime.tryParse(dueAt) → DateTime?
  → AppState.addWorkItem(stageId, title, ..., dueAt)
    → AppDb.addWorkItem(...)
      → INSERT INTO work_items
    → notifyListeners()
  → watchWorkItemsForStage() fires → list updates
```

### Today Screen Population
```
AtlasShell renders TodayScreen
  → watchTodayItems() stream
    → SELECT work_items WHERE status NOT IN ('done','archived')
      AND (status='doing' OR phone_queue=1
           OR priority IN ('high','urgent')
           OR due_at <= tonight)
  → Dart partitions results into: doing / overdue / dueToday / phoneQueue / highPrio
  → Renders in sections
```

### Telegram Send
```
ExportScreen → "Send to Telegram" button
  → AppState.sendTodayToTelegram()
    → _buildTelegram() → reads bot_token, chat_id from AppMeta
    → getTodayItems()
    → for each item: look up Stage → Project for label (DB query, not string hack)
    → TelegramService.formatTodayList(...) → HTML-escaped string
    → AppDb.addOutboxMessage(...) → returns outboxId, status='pending'
    → TelegramService.sendMessage(text)
    → AppDb.markOutboxSent(outboxId) OR markOutboxFailed(outboxId, err)
  → returns (bool ok, String? error)
  → ExportScreen shows result
```

### Ollama (human-in-the-loop)
```
[ReviewScreen / ExportScreen / WorkItemDetailSheet]
  → button pressed
  → AppState.summarizeToday() / summarizeProject() / draftEmailForTask()
    → reads ollama_host, ollama_model from AppMeta
    → OllamaService._chat(system, user) → HTTP POST to Ollama
    → returns OllamaResult { output: String? }
  → if output == null → SnackBar "Ollama not available"
  → else → show OllamaReviewDialog (user sees full text)
    → "Discard" → nothing saved
    → "Save Draft" → AppDb.saveDraft(...) → INSERT INTO drafts
```

---

## 6. Schema Migration History

| Version | Change |
|---------|--------|
| 1 | `projects`, `app_meta` |
| 2 | `stages` added |
| 3 | `work_items` added (basic: id, stage_id, title, owner, completed, created_at) |
| 4 | `work_items` extended (description, status, priority, due_at, updated_at, blocked_reason, source, phone_queue); `drafts`, `daily_reviews`, `outbox_messages` created |

**Migration v4 is defensive:** each `addColumn` is wrapped in try/catch so a partially-applied migration from a prior crash doesn't re-crash. New tables use `CREATE TABLE IF NOT EXISTS`.

---

## 7. Known Limitations / Future Work

| Area | Current state | Notes |
|------|---------------|-------|
| Database encryption | Plaintext SQLite | `db_open.dart` comment explains plan |
| `drafts` screen | Table exists, no route | Next phase |
| Inbound Telegram commands | Not implemented | `/done`, `/snooze` planned |
| Project snapshots | Not implemented | Phase 5 in roadmap |
| `app_meta` settings | Plaintext | Bot token stored unencrypted — fine for personal desktop use |
| `accepted` field on drafts | Schema exists, unused | Reserved for approval flow |
