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

The Library accepts 27 file extensions via a native Windows file picker.
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
| 3 | Search for any cell value — the entry appears because the content is in `extracted_text` |

---

### 1.5 Log (`.log`)

**Sample file:** `demo/sample.log`

| Step | What to do |
|------|-----------|
| 1 | Click **Import**, select `demo/sample.log` |
| 2 | Click the entry — the preview shows log lines as selectable monospace text |
| 3 | Search for "ERROR" — the entry is found instantly from `extracted_text` |

---

### 1.6 XML (`.xml`)

**Sample file:** `demo/sample.xml`

| Step | What to do |
|------|-----------|
| 1 | Click **Import**, select `demo/sample.xml` |
| 2 | Click the entry — the preview shows the raw XML as monospace text |
| 3 | Search for a tag name or value — found via `extracted_text` |

---

### 1.7 YAML (`.yaml` / `.yml`)

**Sample file:** `demo/sample.yaml`

| Step | What to do |
|------|-----------|
| 1 | Click **Import**, select `demo/sample.yaml` |
| 2 | Click the entry — indented YAML is displayed as selectable monospace text |
| 3 | Search for any key name — found via `extracted_text` |

**Note:** `.yml` files behave identically to `.yaml`.

---

### 1.8 INI / TOML / RST

**Sample files:** `demo/sample.ini`, `demo/sample.toml`, `demo/sample.rst`

All three are imported and displayed as plain selectable text. Try importing any one:

| Step | What to do |
|------|-----------|
| 1 | Click **Import**, select `demo/sample.ini` (or `.toml` or `.rst`) |
| 2 | Click the entry — raw config or markup text is shown in monospace |
| 3 | Search for any key or word — found via `extracted_text` |

---

### 1.9 HTML (`.html`)

**Sample file:** `demo/sample.html`

| Step | What to do |
|------|-----------|
| 1 | Click **Import**, select `demo/sample.html` |
| 2 | Click the entry — the preview renders the HTML: table, list, blockquote |
| 3 | Bold, italic, and headings all display as styled content |
| 4 | Search for visible text (e.g. a heading word) — the entry is found |

**What happened:** At import, Atlas stored the raw HTML in `rendered_markdown` (for rendering by `flutter_html`) and the tag-stripped plain text in `extracted_text` (for search). The dual-storage means HTML documents are both visually rich and fully searchable.

---

### 1.10 Email (`.eml`)

**Sample file:** `demo/sample.eml`

| Step | What to do |
|------|-----------|
| 1 | Click **Import**, select `demo/sample.eml` |
| 2 | Click the entry — the preview shows only the message body |
| 3 | RFC-2822 headers (`From:`, `To:`, `Subject:`, etc.) are stripped |
| 4 | Search for a word from the body — found via `extracted_text` |

**What happened:** `stripEmlBody()` in `document_extractor.dart` discards all lines before the first blank line (the RFC-2822 header/body separator). The result is stored in `extracted_text` at import time.

---

### 1.11 Word Document (`.docx`)

**Requires:** a real `.docx` file. Create one in Word or LibreOffice and save it, or use any existing document.

| Step | What to do |
|------|-----------|
| 1 | Click **Import**, select a `.docx` file |
| 2 | Click the entry — the preview shows extracted paragraph text |
| 3 | Search for a word from the document — it is found in the Library |

**What happened:** At import, `extractDocxTextFromBytes()` unzipped the DOCX, parsed `word/document.xml`, and UTF-8 decoded the paragraph text into `extracted_text`.

**Note for `.doc` (legacy Word binary format):** No text extraction is available. The preview shows an "Open in system viewer" button instead.

---

### 1.12 PDF (`.pdf`)

**Requires:** any `.pdf` file.

| Step | What to do |
|------|-----------|
| 1 | Click **Import**, select a `.pdf` file |
| 2 | Click the entry — the preview shows an **"Open in system viewer"** button |
| 3 | Click the button — the PDF opens in your default PDF viewer |

**Note:** In-app PDF rendering is a planned future feature. The app-owned copy is stored and the MIME type is saved (`application/pdf`), so the file is ready when in-app rendering is added.

---

### 1.13 RTF (`.rtf`)

**Requires:** any `.rtf` file (created in WordPad, Word, or LibreOffice).

| Step | What to do |
|------|-----------|
| 1 | Click **Import**, select an `.rtf` file |
| 2 | Click the entry — the preview shows an **"Open in system viewer"** button |
| 3 | Click the button — the file opens in your system's default RTF viewer (WordPad on Windows) |

**Note:** RTF is a binary format. No text is extracted at import; the app-owned copy is stored but not decoded.

---

### 1.14 SVG (`.svg`)

**Requires:** any `.svg` file (e.g. exported from Figma, Inkscape, or a browser).

| Step | What to do |
|------|-----------|
| 1 | Click **Import**, select an `.svg` file |
| 2 | Click the entry — the preview shows an **"Open in system viewer"** button |
| 3 | Click the button — the SVG opens in your default browser or vector viewer |

**Note:** Although SVG is XML-based text, Atlas routes it to the external viewer to preserve fidelity. In-app SVG rendering via `flutter_svg` is not currently wired up.

---

### 1.15 Images (`.jpg` / `.jpeg` / `.png` / `.gif` / `.webp` / `.bmp`)

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
| Plain text | `.txt`, `.log` | Selectable monospace text | Yes → `extracted_text` |
| Markdown | `.md` | Rendered Markdown | Yes → `rendered_markdown` |
| JSON | `.json` | Pretty-printed code block | Yes → `extracted_text` |
| CSV | `.csv` | Selectable monospace text | Yes → `extracted_text` |
| Config / data | `.xml`, `.yaml`, `.yml`, `.ini`, `.toml`, `.rst` | Selectable monospace text | Yes → `extracted_text` |
| HTML | `.html`, `.htm` | Rendered HTML (`flutter_html`) | Yes — raw in `rendered_markdown`, stripped in `extracted_text` |
| Email | `.eml` | Body only (headers stripped) | Yes → `extracted_text` |
| Word (OOXML) | `.docx` | Extracted paragraph text | Yes → `extracted_text` |
| Word (legacy) | `.doc` | Open in system viewer | No |
| RTF | `.rtf` | Open in system viewer | No |
| PDF | `.pdf` | Open in system viewer | No |
| SVG | `.svg` | Open in system viewer | No |
| Images | `.jpg`, `.jpeg`, `.png`, `.gif`, `.webp`, `.bmp` | Inline pan/zoom viewer | No |

All imported files are copied to `atlas_documents/` inside the app data directory.
Moving or deleting the original source file has no effect.
Deleting a document record via the Library UI also removes the app-owned copy from disk.
