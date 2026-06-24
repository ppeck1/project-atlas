# Project Atlas — Demo Walkthrough

Step-by-step guide to exploring every Library file type and the core project management flow.
Sample files for all text-based formats are in the `demo/` directory.

---

## Prerequisites

1. Launch the app: `.\launch.ps1`
2. Create a project (or use an existing one as the active project).
3. Navigate to **Library** in the left nav.

---

## Part 1 — Library File Import

The Library accepts 16 file extensions via a native Windows file picker.
Click **Import** in the Library header to open the picker.

---

### 1.1 Plain Text (`.txt`)

**Sample file:** `demo/sample.txt`

| Step | What to do |
|------|-----------|
| 1 | Click **Import**, select `demo/sample.txt` |
| 2 | The document appears in the left list immediately |
| 3 | Click it — the preview pane shows selectable plain text |
| 4 | Type any word from the file in the search bar — the entry is found |

**What happened under the hood:** The file was copied to `atlas_documents/`. The full text was read and stored in `extracted_text` at import time, so search works without opening the file.

---

### 1.2 Markdown (`.md`)

**Sample file:** `demo/sample.md`

| Step | What to do |
|------|-----------|
| 1 | Click **Import**, select `demo/sample.md` |
| 2 | Click the entry — the preview pane renders formatted Markdown |
| 3 | Headings, bold, tables, code blocks, and lists all display |

**What happened:** Raw Markdown was stored in `rendered_markdown`. `DocumentPreview` uses `flutter_markdown` to render it.

---

### 1.3 JSON (`.json`)

**Sample file:** `demo/sample.json`

| Step | What to do |
|------|-----------|
| 1 | Click **Import**, select `demo/sample.json` |
| 2 | Click the entry — the preview shows pretty-printed, indented JSON |
| 3 | Try **Copy** (top-right button) — the full JSON is on the clipboard |

**What happened:** Raw JSON was stored in `extracted_text`. `DocumentPreview` re-pretty-prints it client-side using `JsonEncoder.withIndent`.

---

### 1.4 CSV (`.csv`)

**Sample file:** `demo/sample.csv`

| Step | What to do |
|------|-----------|
| 1 | Click **Import**, select `demo/sample.csv` |
| 2 | Click the entry — the preview shows the raw CSV as monospace text |
| 3 | Search for "urgent" — the entry appears because the cell is in `extracted_text` |

---

### 1.5 HTML (`.html`)

**Sample file:** `demo/sample.html`

| Step | What to do |
|------|-----------|
| 1 | Click **Import**, select `demo/sample.html` |
| 2 | Click the entry — the preview renders the HTML: table, list, blockquote |
| 3 | Bold, italic, and headings all display as styled content |

**Note:** HTML is not extracted at import time. The stored file is read from disk on every preview open and rendered by `flutter_html`.

---

### 1.6 Email (`.eml`)

**Sample file:** `demo/sample.eml`

| Step | What to do |
|------|-----------|
| 1 | Click **Import**, select `demo/sample.eml` |
| 2 | Click the entry — the preview shows only the message body |
| 3 | RFC-2822 headers (`From:`, `To:`, `Subject:`, etc.) are stripped |

**What happened:** `stripEmlBody()` in `document_extractor.dart` discards all lines before the first blank line (the header/body separator).

---

### 1.7 Word Document (`.docx`)

**Requires:** a real `.docx` file. Create one in Word or LibreOffice and save it, or use any existing document.

| Step | What to do |
|------|-----------|
| 1 | Click **Import**, select a `.docx` file |
| 2 | Click the entry — the preview shows extracted paragraph text |
| 3 | Search for a word from the document — it is found in the Library |

**What happened:** At import, `extractDocxTextFromBytes()` unzipped the DOCX, parsed `word/document.xml`, and UTF-8 decoded the paragraph text into `extracted_text`.

**Note for `.doc` (legacy Word binary format):** No text extraction is available. The preview shows an "Open in system viewer" button instead.

---

### 1.8 PDF (`.pdf`)

**Requires:** any `.pdf` file.

| Step | What to do |
|------|-----------|
| 1 | Click **Import**, select a `.pdf` file |
| 2 | Click the entry — the preview shows an **"Open in system viewer"** button |
| 3 | Click the button — the PDF opens in your default PDF viewer |

**Note:** In-app PDF rendering is a planned future feature. The app-owned copy is stored and the MIME type is saved (`application/pdf`), so the file is ready when in-app rendering is added.

---

### 1.9 Images (`.jpg` / `.jpeg` / `.png` / `.gif` / `.webp` / `.bmp`)

**Requires:** any image file.

| Step | What to do |
|------|-----------|
| 1 | Click **Import**, select an image file (JPG, PNG, GIF, WebP, or BMP) |
| 2 | Click the entry — the preview shows the image in an `InteractiveViewer` |
| 3 | Scroll/pinch to pan and zoom |
| 4 | Switch the type filter to **Images** — the imported image appears |

**What happened:** `_LibraryEntry.fromDocument` detected the image extension and set `mediaType: 'image'`, routing the entry to the image viewer and making it visible in the Images filter.

---

## Part 2 — Library Filters

With several documents imported, try the filter controls in the Library header:

| Filter | What it shows |
|--------|--------------|
| All types | Everything — documents, media, drafts |
| Documents | Non-media, non-draft entries (txt, md, json, csv, html, eml, docx, pdf) |
| Media | `project_media` entries (attached to projects) |
| Images | Entries with `mediaType = 'image'` (both `project_media` and imported image documents) |
| AI Drafts | Ollama-generated drafts saved from any AI action |

---

## Part 3 — Linking Documents to Work Items

Documents can be attached to work items so they appear in AI analysis.

1. Go to **Work** → open a work item detail sheet.
2. In the **Documents** section, click **Link document**.
3. Select a document you imported in Part 1.
4. The document now appears in the work item's document list.
5. Run **Analyze with AI** — the linked document text is included in the Ollama prompt (up to 3 000 chars per document).

---

## Part 4 — AI Structured Project Summary

The structured summary reads linked documents and surfaces relevant ones.

1. Go to **Projects** → select a project → **Project Detail**.
2. Open the **AI Summary** panel.
3. Click **Regenerate** — Atlas sends project metadata + document excerpts to Ollama.
4. The **Relevant Library Docs** section lists documents the AI considered relevant.
5. Each listed document has an **Open in Library** link and a **Show in Explorer** link.

The summary is cached automatically. On the next open, it loads instantly with an age badge.

---

## Part 5 — Project Media Gallery

Project media is separate from the Library document store — it lives in the Project Detail media gallery.

1. Go to **Projects** → select a project → **Project Detail** → scroll to **Media**.
2. Click **Add media** → select an image.
3. The image appears in the gallery with thumbnail, file size, and extension badge.
4. Click **Set as cover** to use it as the project cover image.

Media items also appear in **Library → Media** and **Library → Images** filters.

---

## Quick Reference — Supported Library File Types

| Type | Extensions | Preview | Extracted at import |
|------|-----------|---------|---------------------|
| Plain text | `.txt` | Selectable text | Yes → `extracted_text` |
| Markdown | `.md` | Rendered Markdown | Yes → `rendered_markdown` |
| JSON | `.json` | Pretty-printed code block | Yes → `extracted_text` |
| CSV | `.csv` | Monospace text | Yes → `extracted_text` |
| HTML | `.html`, `.htm` | Rendered HTML | No (read from disk) |
| Email | `.eml` | Body (headers stripped) | No (read from disk) |
| Word (OOXML) | `.docx` | Extracted paragraph text | Yes → `extracted_text` |
| Word (legacy) | `.doc` | Open in system viewer | No |
| PDF | `.pdf` | Open in system viewer | No |
| Images | `.jpg`, `.jpeg`, `.png`, `.gif`, `.webp`, `.bmp` | Inline pan/zoom viewer | No |

All imported files are copied to `atlas_documents/` inside the app data directory.
Moving or deleting the original source file has no effect.
