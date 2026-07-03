from pathlib import Path
from textwrap import wrap

from PIL import Image, ImageDraw, ImageFont


OUT = Path("docs/screenshots")
OUT.mkdir(parents=True, exist_ok=True)

W, H = 1440, 900

COLORS = {
    "page": "#F5F7FA",
    "shell": "#FFFFFF",
    "ink": "#172033",
    "muted": "#667085",
    "soft": "#98A2B3",
    "line": "#D7DEE8",
    "panel": "#FFFFFF",
    "panel_alt": "#F9FAFB",
    "nav": "#1F2937",
    "nav_hot": "#2DD4BF",
    "blue": "#2F80ED",
    "teal": "#008B8B",
    "green": "#239B56",
    "amber": "#B7791F",
    "red": "#C2413A",
    "purple": "#7C3AED",
    "slate": "#475467",
    "cream": "#FFF8E7",
    "rose": "#FCE7E7",
    "mint": "#E7F8F2",
    "sky": "#EAF2FF",
    "violet": "#F1ECFF",
    "peach": "#FFF0E0",
}


def load_font(name, size):
    paths = [
        f"C:/Windows/Fonts/{name}",
        f"/usr/share/fonts/truetype/dejavu/{name}",
    ]
    for path in paths:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


FONT = load_font("segoeui.ttf", 20)
FONT_SM = load_font("segoeui.ttf", 16)
FONT_XS = load_font("segoeui.ttf", 13)
FONT_B = load_font("segoeuib.ttf", 20)
FONT_SB = load_font("segoeuib.ttf", 16)
FONT_H = load_font("segoeuib.ttf", 34)
FONT_H2 = load_font("segoeuib.ttf", 26)
FONT_METRIC = load_font("segoeuib.ttf", 44)


def text_size(draw, value, font):
    box = draw.textbbox((0, 0), value, font=font)
    return box[2] - box[0], box[3] - box[1]


def fit_text(draw, value, max_width, font):
    value = str(value)
    if text_size(draw, value, font)[0] <= max_width:
        return value
    suffix = "..."
    lo, hi = 0, len(value)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if text_size(draw, value[:mid] + suffix, font)[0] <= max_width:
            lo = mid
        else:
            hi = mid - 1
    return value[:lo].rstrip() + suffix


def draw_text(draw, xy, value, fill=None, font=None, max_width=None):
    fill = fill or COLORS["ink"]
    font = font or FONT
    if max_width:
        value = fit_text(draw, value, max_width, font)
    draw.text(xy, value, fill=fill, font=font)


def draw_wrapped(draw, xy, value, width, fill=None, font=None, lines=2, step=24):
    fill = fill or COLORS["muted"]
    font = font or FONT_SM
    words_per_line = max(12, width // 9)
    wrapped = []
    for paragraph in str(value).split("\n"):
        wrapped.extend(wrap(paragraph, width=words_per_line) or [""])
    y = xy[1]
    for index, line in enumerate(wrapped[:lines]):
        if index == lines - 1 and len(wrapped) > lines:
            line = fit_text(draw, line + "...", width, font)
        draw_text(draw, (xy[0], y), line, fill, font, width)
        y += step


def rounded(draw, box, radius=12, fill=None, outline=None, width=1):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def pill(draw, x, y, label, color, bg=None):
    bg = bg or COLORS["panel_alt"]
    pad = 14
    w = text_size(draw, label, FONT_XS)[0] + pad * 2
    rounded(draw, [x, y, x + w, y + 28], 14, bg, color)
    draw_text(draw, (x + pad, y + 7), label, color, FONT_XS)
    return x + w + 8


def button(draw, box, label, primary=False):
    fill = COLORS["blue"] if primary else COLORS["panel"]
    outline = COLORS["blue"] if primary else COLORS["line"]
    color = "#FFFFFF" if primary else COLORS["slate"]
    rounded(draw, box, 8, fill, outline)
    tw, th = text_size(draw, label, FONT_SB)
    x = box[0] + (box[2] - box[0] - tw) / 2
    y = box[1] + (box[3] - box[1] - th) / 2 - 1
    draw_text(draw, (x, y), label, color, FONT_SB)


def base(selected, title, subtitle=None):
    image = Image.new("RGB", (W, H), COLORS["page"])
    draw = ImageDraw.Draw(image)
    rounded(draw, [36, 28, W - 36, H - 28], 22, COLORS["shell"], COLORS["line"])
    draw.rectangle([36, 50, 116, H - 50], fill=COLORS["nav"])
    draw.rounded_rectangle([36, 28, 116, H - 28], radius=22, fill=COLORS["nav"])
    draw.rectangle([94, 28, 116, H - 28], fill=COLORS["nav"])
    draw_text(draw, (58, 54), "AT", COLORS["nav_hot"], FONT_B)
    draw_text(draw, (54, 78), "LAS", "#CBD5E1", FONT_XS)
    nav_items = [
        ("Today", "T", "Today"),
        ("Projects", "P", "Projects"),
        ("Operations", "O", "Ops"),
        ("Library", "L", "Library"),
        ("Settings", "S", "Settings"),
    ]
    y = 144
    for label, glyph, nav_label in nav_items:
        active = label == selected
        if active:
            rounded(draw, [52, y - 14, 100, y + 44], 14, "#334155")
            draw.rectangle([36, y - 3, 42, y + 33], fill=COLORS["nav_hot"])
        draw_text(draw, (68, y), glyph, COLORS["nav_hot"] if active else "#CBD5E1", FONT_B)
        draw_text(draw, (50, y + 31), nav_label, "#E2E8F0" if active else "#94A3B8", FONT_XS, 58)
        y += 92
    draw_text(draw, (154, 62), title, COLORS["ink"], FONT_H)
    if subtitle:
        draw_text(draw, (154, 106), subtitle, COLORS["muted"], FONT_SM, 780)
    draw.line([132, 142, W - 64, 142], fill=COLORS["line"], width=1)
    return image, draw


def metric_card(draw, box, label, value, detail, color, bg):
    rounded(draw, box, 14, bg, COLORS["line"])
    draw_text(draw, (box[0] + 20, box[1] + 18), label, COLORS["muted"], FONT_SB, box[2] - box[0] - 40)
    draw_text(draw, (box[0] + 20, box[1] + 48), value, color, FONT_METRIC)
    draw_text(draw, (box[0] + 20, box[1] + 104), detail, COLORS["slate"], FONT_XS, box[2] - box[0] - 40)


def table_header(draw, x, y, widths, labels):
    xx = x
    for width, label in zip(widths, labels):
        draw_text(draw, (xx, y), label.upper(), COLORS["soft"], FONT_XS, width)
        xx += width
    draw.line([x, y + 28, x + sum(widths), y + 28], fill=COLORS["line"])


def make_today():
    image, draw = base(
        "Today",
        "Today",
        "Daily operating view: doing now, overdue, blocked, phone queue, and high-priority work.",
    )
    cards = [
        ("Doing", "2", "Active work items", COLORS["blue"], COLORS["sky"]),
        ("Overdue", "1", "Needs review today", COLORS["red"], COLORS["rose"]),
        ("Blocked", "1", "Waiting on decision", COLORS["purple"], COLORS["violet"]),
        ("Phone queue", "3", "Ready for Telegram", COLORS["teal"], COLORS["mint"]),
    ]
    x = 154
    for label, value, detail, color, bg in cards:
        metric_card(draw, [x, 172, x + 286, 312], label, value, detail, color, bg)
        x += 306

    rounded(draw, [154, 342, 872, 814], 14, COLORS["panel"], COLORS["line"])
    draw_text(draw, (178, 366), "Focus list", COLORS["ink"], FONT_H2)
    rows = [
        ("Refresh README screenshots", "Docs", "Doing", "High"),
        ("Review SQLCipher passphrase plan", "Security", "Overdue", "High"),
        ("Approve Atlas agent proposal", "Library", "Blocked", "Review"),
        ("Send current task list to phone", "Telegram", "Ready", "Normal"),
        ("Validate runtime profile commands", "Projects", "Next", "High"),
    ]
    table_header(draw, 178, 412, [360, 120, 110, 90], ["Work item", "Area", "State", "Priority"])
    y = 458
    for item, area, state, priority in rows:
        draw.line([178, y + 48, 846, y + 48], fill=COLORS["line"])
        draw_text(draw, (178, y), item, COLORS["ink"], FONT_SB, 350)
        draw_text(draw, (538, y), area, COLORS["slate"], FONT_SM, 110)
        state_color = COLORS["green"] if state in ("Doing", "Ready") else COLORS["amber"] if state == "Next" else COLORS["red"]
        pill(draw, 658, y - 4, state, state_color, COLORS["panel_alt"])
        draw_text(draw, (778, y), priority, COLORS["muted"], FONT_SM, 80)
        y += 68

    rounded(draw, [900, 342, 1328, 814], 14, COLORS["panel"], COLORS["line"])
    draw_text(draw, (924, 366), "Operator signals", COLORS["ink"], FONT_H2)
    signals = [
        ("Human-in-loop AI", "Ollama drafts are advisory until reviewed."),
        ("Local storage", "SQLite via Drift, schema version 19."),
        ("Outbound only", "Telegram sends task lists and logs attempts."),
        ("Attention filters", "Blocked, overdue, doing, and high priority stay visible."),
    ]
    y = 424
    for title, body in signals:
        rounded(draw, [924, y, 1304, y + 78], 10, COLORS["panel_alt"], COLORS["line"])
        draw_text(draw, (944, y + 14), title, COLORS["ink"], FONT_SB, 330)
        draw_wrapped(draw, (944, y + 40), body, 330, COLORS["muted"], FONT_XS, 2, 18)
        y += 94
    image.save(OUT / "today.png")


def make_projects():
    image, draw = base(
        "Projects",
        "Projects",
        "Category-grouped projects with pins, filters, runtime actions, lifecycle fields, and bundle export.",
    )
    filters = ["Status: Open", "Phase: Any", "Priority: High+", "Tags: Work", "Context: Local"]
    x = 154
    for item in filters:
        rounded(draw, [x, 172, x + 190, 212], 9, COLORS["panel"], COLORS["line"])
        draw_text(draw, (x + 16, 184), item, COLORS["slate"], FONT_SM, 158)
        x += 206
    button(draw, [1204, 172, 1328, 212], "New", True)

    rounded(draw, [154, 242, 1328, 810], 14, COLORS["panel"], COLORS["line"])
    draw_text(draw, (178, 268), "Development", COLORS["ink"], FONT_H2)
    pill(draw, 350, 270, "pinned category", COLORS["teal"], COLORS["mint"])
    draw_text(draw, (178, 310), "Pinned projects sort first; lifecycle, tags, phase, and runtime controls remain visible.", COLORS["muted"], FONT_SM, 760)
    projects = [
        ("Project Atlas", "Local-first command center with Today, Operations, Library, and Settings workflows.", "Active", "Ship", "Runtime ready", COLORS["blue"]),
        ("Project Ops Capsule", "Repo-local launch, test, documentation, and closeout evidence for governed projects.", "Review", "Audit", "Capsule", COLORS["purple"]),
        ("Dev Launchpad", "Project-owned launch metadata and runtime-visible YAML alignment.", "Active", "Stabilize", "Launch/Test", COLORS["green"]),
        ("Telegram Outbox", "Outbound phone handoff with escaped HTML and local attempt logging.", "Paused", "Support", "Outbox", COLORS["amber"]),
    ]
    y = 356
    for name, desc, status, phase, action, color in projects:
        rounded(draw, [178, y, 1304, y + 92], 12, COLORS["panel_alt"], color if name == "Project Atlas" else COLORS["line"], 2 if name == "Project Atlas" else 1)
        rounded(draw, [202, y + 20, 252, y + 70], 12, "#FFFFFF", COLORS["line"])
        draw_text(draw, (219, y + 34), name[0], color, FONT_B)
        draw_text(draw, (276, y + 16), name, COLORS["ink"], FONT_B, 300)
        draw_wrapped(draw, (276, y + 44), desc, 500, COLORS["muted"], FONT_XS, 2, 18)
        xx = 820
        xx = pill(draw, xx, y + 18, status, color)
        xx = pill(draw, xx, y + 18, phase, COLORS["slate"])
        pill(draw, xx, y + 18, action, COLORS["teal"])
        button(draw, [1150, y + 50, 1278, y + 80], "Open")
        y += 112
    image.save(OUT / "projects.png")


def make_operations():
    image, draw = base(
        "Operations",
        "Operations",
        "Manual shallow scans, candidate triage, reviewed registry records, enrichment runs, and project health.",
    )
    tabs = ["Scans", "Review", "Registered", "Enrichment", "Project Health"]
    x = 154
    for tab in tabs:
        active = tab == "Review"
        rounded(draw, [x, 166, x + 158, 208], 10, COLORS["sky"] if active else COLORS["panel"], COLORS["blue"] if active else COLORS["line"])
        draw_text(draw, (x + 20, 179), tab, COLORS["blue"] if active else COLORS["slate"], FONT_SB, 118)
        x += 170
    button(draw, [1136, 166, 1328, 208], "Run scan", True)

    metric_card(draw, [154, 238, 414, 370], "Candidates", "3", "Need accept, link, or ignore", COLORS["amber"], COLORS["cream"])
    metric_card(draw, [438, 238, 698, 370], "Registered", "18", "Filtered to needs action", COLORS["green"], COLORS["mint"])
    metric_card(draw, [722, 238, 982, 370], "Open findings", "7", "Grouped by project health", COLORS["red"], COLORS["rose"])
    metric_card(draw, [1006, 238, 1328, 370], "Scan policy", "2", "Default max depth", COLORS["teal"], COLORS["sky"])

    rounded(draw, [154, 404, 1328, 816], 14, COLORS["panel"], COLORS["line"])
    draw_text(draw, (178, 430), "Review candidates", COLORS["ink"], FONT_H2)
    chips = [("Needs action", COLORS["blue"]), ("Known", COLORS["slate"]), ("Ignored", COLORS["slate"]), ("All", COLORS["slate"])]
    x = 980
    for label, color in chips:
        x = pill(draw, x, 432, label, color, COLORS["sky"] if label == "Needs action" else COLORS["panel_alt"])
    candidates = [
        ("B:/dev/dev.launchpad", "Strong root: README, pubspec, .git. Import as project or link to existing record.", "candidate"),
        ("B:/dev/Project_Atlas/project-atlas-main", "Already linked. Refresh docs, media, source rows, and runtime profile.", "linked"),
        ("B:/dev/ops_capsule", "Capsule metadata present. Mark as governed support project after review.", "needs review"),
    ]
    y = 500
    for path, detail, state in candidates:
        rounded(draw, [178, y, 1304, y + 86], 10, COLORS["panel_alt"], COLORS["line"])
        draw_text(draw, (202, y + 14), path, COLORS["ink"], FONT_SB, 560)
        draw_wrapped(draw, (202, y + 42), detail, 650, COLORS["muted"], FONT_XS, 2, 17)
        color = COLORS["green"] if state == "linked" else COLORS["amber"] if state == "candidate" else COLORS["purple"]
        pill(draw, 896, y + 18, state, color)
        button(draw, [1038, y + 16, 1116, y + 50], "Accept")
        button(draw, [1128, y + 16, 1204, y + 50], "Link")
        button(draw, [1216, y + 16, 1284, y + 50], "Ignore")
        y += 104
    image.save(OUT / "operations.png")


def make_library():
    image, draw = base(
        "Library",
        "Library",
        "Documents, media, and AI drafts with search, project filters, previews, and proposal review.",
    )
    rounded(draw, [154, 166, 620, 208], 10, COLORS["panel"], COLORS["line"])
    draw_text(draw, (178, 179), "Search title and content", COLORS["soft"], FONT_SM)
    rounded(draw, [644, 166, 826, 208], 10, COLORS["panel"], COLORS["line"])
    draw_text(draw, (666, 179), "Project Atlas", COLORS["slate"], FONT_SM)
    rounded(draw, [850, 166, 1008, 208], 10, COLORS["panel"], COLORS["line"])
    draw_text(draw, (872, 179), "AI Drafts", COLORS["slate"], FONT_SM)
    button(draw, [1204, 166, 1328, 208], "Import", True)

    rounded(draw, [154, 238, 482, 816], 14, COLORS["panel"], COLORS["line"])
    draw_text(draw, (178, 264), "Items", COLORS["ink"], FONT_H2)
    entries = [
        ("Project Atlas Today Summary", "AI Draft", COLORS["green"]),
        ("Agent proposal: update status", "Proposal", COLORS["purple"]),
        ("Runtime profile checklist", "Markdown", COLORS["blue"]),
        ("Operations scan warning", "JSON", COLORS["amber"]),
        ("Cover image capture", "Media", COLORS["teal"]),
    ]
    y = 316
    for index, (name, kind, color) in enumerate(entries):
        fill = COLORS["sky"] if index == 0 else COLORS["panel_alt"]
        rounded(draw, [178, y, 458, y + 70], 10, fill, color if index == 0 else COLORS["line"])
        draw_text(draw, (198, y + 12), name, COLORS["ink"], FONT_SB, 236)
        draw_text(draw, (198, y + 40), kind, color, FONT_XS, 150)
        y += 86

    rounded(draw, [514, 238, 1328, 816], 14, COLORS["panel"], COLORS["line"])
    draw_text(draw, (542, 268), "Project Atlas Today Summary", COLORS["ink"], FONT_H2, 620)
    x = pill(draw, 542, 314, "today_summary", COLORS["green"], COLORS["mint"])
    x = pill(draw, x, 314, "Project Atlas", COLORS["blue"], COLORS["sky"])
    pill(draw, x, 314, "human review", COLORS["purple"], COLORS["violet"])
    draw_text(draw, (542, 368), "Preview", COLORS["ink"], FONT_B)
    rounded(draw, [542, 406, 1292, 748], 12, COLORS["panel_alt"], COLORS["line"])
    preview = [
        ("Summary", "2 doing items, 1 overdue security review, and 1 blocked proposal need attention today."),
        ("Evidence", "Library-backed project summaries use ranked document packets with warnings before save."),
        ("Agent boundary", "Proposal-first writes are saved as reviewable drafts; approval remains in the desktop app."),
        ("Media", "Project media can be attached to work items and queued LLM tasks for local context."),
    ]
    y = 434
    for heading, body in preview:
        draw_text(draw, (570, y), heading, COLORS["ink"], FONT_SB, 150)
        draw_wrapped(draw, (700, y), body, 520, COLORS["muted"], FONT_SM, 2, 22)
        y += 76
    image.save(OUT / "library.png")


def make_settings():
    image, draw = base(
        "Settings",
        "Settings",
        "Integrations, AI summary setup, activity log, export tools, contacts, backup, and admin controls.",
    )
    tabs = ["Integrations", "AI Summaries", "Activity Log", "Export", "Workforce", "Admin"]
    x = 154
    for tab in tabs:
        active = tab == "AI Summaries"
        width = 150 if tab != "AI Summaries" else 170
        rounded(draw, [x, 166, x + width, 208], 10, COLORS["violet"] if active else COLORS["panel"], COLORS["purple"] if active else COLORS["line"])
        draw_text(draw, (x + 18, 179), tab, COLORS["purple"] if active else COLORS["slate"], FONT_SB, width - 36)
        x += width + 12

    rounded(draw, [154, 238, 654, 816], 14, COLORS["panel"], COLORS["line"])
    draw_text(draw, (178, 266), "Project AI summaries", COLORS["ink"], FONT_H2)
    draw_wrapped(draw, (178, 310), "Opt-in project summaries use local Ollama models, Library evidence, packet previews, warnings, and schema validation.", 420, COLORS["muted"], FONT_SM, 3, 24)
    controls = [
        ("Enable project AI summaries", "Off by default"),
        ("Include Library evidence", "On by default after opt-in"),
        ("Bulk refresh", "Gated by separate confirmation"),
        ("Invalid output", "Fails closed with reasons"),
    ]
    y = 404
    for title, detail in controls:
        rounded(draw, [178, y, 626, y + 76], 10, COLORS["panel_alt"], COLORS["line"])
        draw.ellipse([202, y + 24, 230, y + 52], fill=COLORS["green"] if "Library" in title else COLORS["line"], outline=COLORS["line"])
        draw_text(draw, (248, y + 16), title, COLORS["ink"], FONT_SB, 320)
        draw_text(draw, (248, y + 44), detail, COLORS["muted"], FONT_XS, 320)
        y += 92

    rounded(draw, [686, 238, 1328, 816], 14, COLORS["panel"], COLORS["line"])
    draw_text(draw, (714, 266), "Operator setup", COLORS["ink"], FONT_H2)
    setup = [
        ("Ollama host", "http://localhost:11434", COLORS["blue"]),
        ("Summary model", "qwen3.5:9b or installed local model", COLORS["teal"]),
        ("Evidence cap", "3000 chars per document, 16000 total", COLORS["amber"]),
        ("Export tools", "Backup, Telegram task list, project bundle", COLORS["green"]),
        ("Admin", "Open app data folder and inspect local storage", COLORS["slate"]),
    ]
    y = 328
    for label, value, color in setup:
        rounded(draw, [714, y, 1292, y + 72], 10, COLORS["panel_alt"], COLORS["line"])
        draw_text(draw, (738, y + 15), label, color, FONT_SB, 180)
        draw_text(draw, (940, y + 15), value, COLORS["ink"], FONT_SM, 330)
        y += 88
    image.save(OUT / "settings.png")


if __name__ == "__main__":
    make_today()
    make_projects()
    make_operations()
    make_library()
    make_settings()
    print("Generated README screenshots in docs/screenshots/")
