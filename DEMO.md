# Project Atlas demo walkthrough

This walkthrough uses only the invented files under `demo/`. Do not import a
real workspace when preparing screenshots or a portfolio demonstration.

## Start the app

```powershell
.\launch.ps1 -Full
```

Create a project named `Sample Workspace`, then use that project for the steps
below.

## 1. Build a small workboard

1. Add three work items: `Review example brief`, `Validate import`, and
   `Prepare demo release`.
2. Move them into Doing, Next, and Waiting.
3. Give one item a high priority and another a synthetic due date.
4. Open Today and verify the attention groups update.

This demonstrates project scoping, lifecycle state, priorities, and the daily
operating view without exposing a real backlog.

## 2. Import the synthetic Library set

Open Library, select `Sample Workspace`, and import files from `demo/`.

| Fixture | Expected preview |
|---|---|
| `sample.md` | Rendered Markdown |
| `sample.html` | Rendered HTML plus searchable text |
| `sample.json` | Pretty-printed JSON |
| `sample.csv`, `sample.log`, `sample.xml` | Monospace searchable text |
| `sample.yaml`, `sample.toml`, `sample.ini` | Searchable configuration text |
| `sample.eml` | Message body with transport headers removed |
| `sample.rst`, `sample.txt` | Plain searchable text |

Link one imported document to `Review example brief` and confirm it appears in
the work-item detail sheet.

## 3. Show project operations

Create a disposable folder containing a README and a supported project
manifest. In Operations:

1. Run a shallow scan against only that disposable parent folder.
2. Review the candidate before accepting it.
3. Preview refresh actions before applying them.
4. Open the resulting run and finding history.

Delete the disposable folder after the demo. Never scan a real project root for
public screenshots.

## 4. Show review-gated AI behavior

If a local Ollama model is available, enable summaries for `Sample Workspace`
and request a preview. Review the evidence packet and warnings before saving.

For the queue workflow, create a synthetic task and show that results land as a
draft or proposal requiring review. The useful portfolio point is the boundary:
model output is not silently treated as accepted project truth.

## 5. Show runtime safety

Create a runtime profile with harmless demo commands, such as a command that
prints a message and exits. Verify that:

- Atlas displays exactly what the operator configured.
- Nothing runs merely because the profile has been saved.
- Manual execution records status, output, and exit code.

## 6. Reset the demonstration

Delete `Sample Workspace` and its imported fixture records, or reset the local
app-data directory. The repository itself contains no live database or project
inventory.
