from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


OUT = Path("docs/screenshots")
OUT.mkdir(parents=True, exist_ok=True)

W, H = 1280, 760
BG = "#0F1115"
PANEL = "#151A22"
LINE = "#273044"
PRIMARY = "#79A7FF"
TEXT = "#E8ECF4"
MUTED = "#8A96A8"
DIM = "#5F6B7A"
GREEN = "#4CAF50"
AMBER = "#FFC107"
RED = "#F44336"
ORANGE = "#FF9800"
PURPLE = "#9C27B0"
BLUE = "#2196F3"
TEAL = "#00BCD4"


def load_font(path: str, size: int):
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default()


FONT = load_font("C:/Windows/Fonts/segoeui.ttf", 20)
FONT_B = load_font("C:/Windows/Fonts/segoeuib.ttf", 20)
FONT_S = load_font("C:/Windows/Fonts/segoeui.ttf", 15)
FONT_XS = load_font("C:/Windows/Fonts/segoeui.ttf", 12)
FONT_H = load_font("C:/Windows/Fonts/segoeuib.ttf", 32)
FONT_METRIC = load_font("C:/Windows/Fonts/segoeuib.ttf", 42)


def rr(d, xy, r, fill, outline=None, width=1):
    d.rounded_rectangle(xy, radius=r, fill=fill, outline=outline, width=width)


def text(d, xy, value, fill=TEXT, font=FONT):
    d.text(xy, value, fill=fill, font=font)


def nav(d, selected):
    d.rectangle([0, 0, 72, H], fill=PANEL)
    d.line([72, 0, 72, H], fill=LINE)
    # Logo placeholder
    rr(d, [18, 14, 54, 50], 10, BG, PRIMARY)
    text(d, (22, 20), "PA", PRIMARY, FONT_XS)
    text(d, (19, 56), "ATLAS", PRIMARY, FONT_XS)
    items = [("Today", "T"), ("Projects", "P"), ("Ops", "O"), ("Library", "L")]
    y = 104
    for name, glyph in items:
        is_selected = name == selected
        if is_selected:
            rr(d, [10, y - 8, 62, y + 48], 18, "#1B2B4A")
        text(d, (31, y), glyph, PRIMARY if is_selected else MUTED, FONT_B)
        text(d, (12, y + 28), name, PRIMARY if is_selected else MUTED, FONT_XS)
        y += 78
    settings_selected = selected == "Settings"
    if settings_selected:
        rr(d, [10, H - 92, 62, H - 36], 18, "#1B2B4A")
    text(d, (18, H - 76), "S", PRIMARY if settings_selected else MUTED, FONT_B)
    text(d, (10, H - 48), "Settings", PRIMARY if settings_selected else MUTED, FONT_XS)


def appbar(d, title, right=""):
    d.rectangle([73, 0, W, 64], fill=BG)
    text(d, (96, 18), title, TEXT, FONT_B)
    if right:
        text(d, (W - 210, 22), right, MUTED, FONT_S)
    d.line([73, 64, W, 64], fill=LINE)


def metric(d, x, label, value, color):
    rr(d, [x, 96, x + 260, 184], 14, PANEL, LINE)
    bbox = d.textbbox((0, 0), str(value), font=FONT_METRIC)
    text(d, (x + 130 - (bbox[2] - bbox[0]) / 2, 108), str(value), color, FONT_METRIC)
    text(d, (x + 105, 154), label, MUTED, FONT_S)


def pill(d, x, y, label, color):
    # Dark fill + colored outline keeps the colored label text readable
    # (an alpha fill flattens to opaque on RGB images and hides the text).
    width = len(label) * 8 + 18
    rr(d, [x, y, x + width, y + 24], 4, "#10151E", color)
    text(d, (x + 9, y + 4), label, color, FONT_XS)
    return x + width + 10


def make_today():
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    nav(d, "Today")
    appbar(d, "Today", "Fri Jul 3")
    metric(d, 96, "Doing", 2, AMBER)
    metric(d, 376, "Overdue", 1, RED)
    metric(d, 656, "Blocked", 1, PURPLE)
    metric(d, 936, "Total", 7, TEXT)
    sections = [
        (
            "Doing Now",
            AMBER,
            [
                ("Update docs to schema v19", "README, HANDOFF, VARIABLE_MAP updated; screenshots refreshed", "HIGH", "7/3", False),
                ("Run flutter test — full suite passing", "operations registry + runtime service + summary contract tests", "URGENT", "7/3", True),
            ],
        ),
        (
            "Overdue",
            RED,
            [("Review encryption plan", "SQLCipher passphrase before broader distribution", "HIGH", "6/30", False)],
        ),
        (
            "Phone / Follow-up",
            BLUE,
            [("Send today list to phone", "Telegram outbound queue — tap to toggle phone queue", "NORMAL", "", True)],
        ),
        (
            "High Priority",
            ORANGE,
            [
                ("Configure runtime profile for Atlas", "Launch/test/capsule commands from Project Detail > Runtime", "HIGH", "", False),
                ("Draft email for blocked task", "Ollama email draft — human review before save", "HIGH", "", False),
                ("Review agent proposals in Library", "Pending atlas_agent_proposal drafts — approve or reject", "HIGH", "", False),
            ],
        ),
    ]
    y = 220
    for title, color, rows in sections:
        text(d, (96, y), title, color, FONT_B)
        y += 30
        for name, desc, prio, due, phone in rows:
            rr(d, [96, y, 1184, y + 70], 12, PANEL, LINE)
            d.rectangle([116, y + 21, 142, y + 47], outline=MUTED, width=2)
            text(d, (160, y + 12), name, TEXT, FONT_B)
            text(d, (160, y + 40), desc, MUTED, FONT_S)
            if prio not in ("NORMAL",):
                pill(d, 1040, y + 14, prio, ORANGE if prio == "HIGH" else RED)
            if due:
                text(d, (1105, y + 42), due, ORANGE if due == "6/23" else RED, FONT_S)
            if phone:
                text(d, (1146, y + 14), "phone", BLUE, FONT_XS)
            y += 82
        y += 10
    im.save(OUT / "today.png")


def make_projects():
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    nav(d, "Projects")
    appbar(d, "Projects")
    # Filter bar
    rr(d, [96, 72, 300, 106], 8, BG, LINE)
    text(d, (116, 82), "All statuses", MUTED, FONT_S)
    rr(d, [316, 72, 500, 106], 8, BG, LINE)
    text(d, (336, 82), "All phases", MUTED, FONT_S)
    rr(d, [516, 72, 700, 106], 8, BG, LINE)
    text(d, (536, 82), "All priorities", MUTED, FONT_S)
    rr(d, [716, 72, 870, 106], 8, BG, LINE)
    text(d, (736, 82), "All tags", MUTED, FONT_S)
    rr(d, [886, 72, 1030, 106], 8, BG, LINE)
    text(d, (906, 82), "All contexts", MUTED, FONT_S)
    rr(d, [1040, 17, 1184, 50], 8, PRIMARY)
    text(d, (1060, 24), "New project", BG, FONT_S)
    # Category group header (pinned category)
    text(d, (96, 122), "Development", PRIMARY, FONT_B)
    pill(d, 240, 124, "pinned", PRIMARY)
    text(d, (330, 126), "4 projects", DIM, FONT_S)
    rows = [
        ("Project Atlas", "Local-first personal project command center", "active", "ship", True, ["#work", "#dev"], True),
        ("Document Library Integration", "Import local files and link to work items for AI context", "active", "build", False, ["#dev"], False),
        ("Contact Directory", "Reusable people records linked across all owner fields", "active", "stabilize", False, ["#work"], False),
        ("Telegram Outbox", "Outbound task list with HTML escaping and outbox logging", "paused", "stabilize", False, ["#work"], False),
    ]
    y = 158
    for title, desc, status, phase, active, tags, has_runtime in rows:
        rr(d, [96, y, 1184, y + 98], 14, PANEL, PRIMARY if active else LINE, 2 if active else 1)
        rr(d, [116, y + 18, 154, y + 56], 10, "#1B2B4A" if active else "#243040")
        text(d, (128, y + 26), "P", PRIMARY if active else MUTED, FONT_B)
        text(d, (174, y + 14), title, TEXT, FONT_B)
        text(d, (174, y + 43), desc, MUTED, FONT_S)
        x = pill(d, 174, y + 70, status, GREEN if status == "active" else ORANGE)
        x = pill(d, x, y + 70, phase, BLUE if phase in ("test", "build") else (GREEN if phase == "ship" else MUTED))
        for tag in tags:
            x = pill(d, x, y + 70, tag, TEAL)
        if has_runtime:
            x = pill(d, x, y + 70, "runtime: launch · test · capsule", GREEN)
        if active:
            pill(d, 1060, y + 18, "ACTIVE", PRIMARY)
        text(d, (1156, y + 36), ">", DIM, FONT_B)
        y += 112
    im.save(OUT / "projects.png")


def make_library():
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    nav(d, "Library")
    d.rectangle([73, 0, W, 62], fill=PANEL)
    text(d, (96, 18), "Library", TEXT, FONT_B)
    rr(d, [220, 14, 650, 48], 8, BG, LINE)
    text(d, (244, 22), "Search title and content...", DIM, FONT_S)
    rr(d, [670, 14, 830, 48], 8, BG, LINE)
    text(d, (690, 22), "All projects", MUTED, FONT_S)
    rr(d, [846, 14, 976, 48], 8, BG, LINE)
    text(d, (866, 22), "All types", MUTED, FONT_S)
    text(d, (1000, 23), "6 items", DIM, FONT_S)
    rr(d, [1084, 14, 1178, 48], 8, PRIMARY)
    text(d, (1106, 22), "Import", BG, FONT_S)
    d.line([73, 62, W, 62], fill=LINE)
    d.rectangle([73, 63, 393, H], fill=BG)
    d.line([393, 63, 393, H], fill=LINE)
    entries = [
        ("Project Atlas — Today Summary", "AI Draft", GREEN),
        ("Contact import format spec", "MD", MUTED),
        ("Schema v10 migration notes", "TXT", MUTED),
        ("Launch checklist", "MD", MUTED),
        ("Governance bottleneck review", "AI Draft", GREEN),
    ]
    y = 82
    for i, (title, kind, color) in enumerate(entries):
        if i == 0:
            d.rectangle([73, y - 6, 393, y + 62], fill="#17233A")
            d.rectangle([73, y - 6, 76, y + 62], fill=PRIMARY)
        text(d, (96, y), title, PRIMARY if i == 0 else TEXT, FONT_S)
        text(d, (96, y + 26), "Project Atlas", DIM, FONT_XS)
        pill(d, 288, y + 4, kind, color)
        y += 72
    text(d, (430, 104), "Project Atlas — Today Summary", TEXT, FONT_H)
    pill(d, 430, 152, "AI Draft - today_summary", GREEN)
    text(d, (430, 190), "Jul 3, 2026  ·  Project Atlas", MUTED, FONT_S)
    rr(d, [430, 234, 1178, 700], 8, PANEL, LINE)
    body = [
        "Today summary (schema v19):",
        "- 2 items doing: runtime profiles shipped, docs refresh in progress.",
        "- 1 overdue: encryption plan review (SQLCipher passphrase).",
        "- Runtime actions available: launch, test, and capsule per project.",
        "- Operations Project Health groups open enrichment findings.",
        "- Agent proposals pending review in the Library filter.",
        "- Media gallery: 3 images attached to Project Atlas.",
        "Ollama output is advisory — saved only after human review.",
    ]
    yy = 262
    for line in body:
        text(d, (460, yy), line, TEXT if yy == 262 else MUTED, FONT_B if yy == 262 else FONT_S)
        yy += 40
    im.save(OUT / "library.png")


def make_operations():
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    nav(d, "Ops")
    d.rectangle([73, 0, W, 96], fill=PANEL)
    text(d, (96, 18), "Operations", TEXT, FONT_B)
    tabs = ["Scans", "Review Candidates", "Registered Projects", "Enrichment", "Project Health"]
    x = 96
    for i, tab in enumerate(tabs):
        text(d, (x, 66), tab, PRIMARY if i == 1 else MUTED, FONT_S)
        if i == 1:
            d.line([x, 91, x + len(tab) * 9, 91], fill=PRIMARY, width=3)
        x += len(tab) * 11 + 44
    # Scan controls row
    rr(d, [96, 112, 300, 146], 8, PRIMARY)
    text(d, (120, 120), "Run manual scan", BG, FONT_S)
    rr(d, [316, 112, 470, 146], 8, BG, LINE)
    text(d, (336, 120), "Add folder...", MUTED, FONT_S)
    text(d, (500, 121), "Last scan: Jul 3, 2026 — 14 observations, 3 candidates", DIM, FONT_S)
    # Queue filter chips
    x = 96
    for i, chip in enumerate(["Needs action", "Known", "Ignored", "All"]):
        width = len(chip) * 9 + 28
        rr(d, [x, 162, x + width, 194], 16, "#1B2B4A" if i == 0 else BG, PRIMARY if i == 0 else LINE)
        text(d, (x + 14, 169), chip, PRIMARY if i == 0 else MUTED, FONT_S)
        x += width + 12
    candidates = [
        ("dev_launchpad", "C:\\dev\\dev_launchpad", "candidate", ORANGE,
         "Strong root: pubspec.yaml, README.md, .git — depth 1"),
        ("ops_capsule", "C:\\dev\\ops_capsule", "candidate", ORANGE,
         "Strong root: project_manifest.json, capsule profile — depth 1"),
        ("project-atlas", "C:\\dev\\project-atlas", "linked", GREEN,
         "Linked to Atlas project — refresh available instead of re-triage"),
    ]
    y = 212
    for name, path, state, color, detail in candidates:
        rr(d, [96, y, 1184, y + 118], 12, PANEL, LINE)
        text(d, (116, y + 12), name, TEXT, FONT_B)
        pill(d, 1080, y + 14, state, color)
        text(d, (116, y + 42), path, MUTED, FONT_S)
        text(d, (116, y + 66), detail, DIM, FONT_XS)
        bx = 116
        for label in ["Accept", "Link to project", "Ignore", "Needs review"]:
            width = len(label) * 8 + 26
            rr(d, [bx, y + 86, bx + width, y + 112], 6, BG, LINE)
            text(d, (bx + 13, y + 91), label, MUTED, FONT_XS)
            bx += width + 10
        y += 132
    # Bulk action bar
    rr(d, [96, y + 4, 1184, y + 46], 10, "#17233A", PRIMARY)
    text(d, (116, y + 14), "3 selected", PRIMARY, FONT_S)
    text(d, (240, y + 14), "Bulk: Accept · Ignore · Needs review · Ignore descendants", MUTED, FONT_S)
    im.save(OUT / "operations.png")


def make_settings():
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    nav(d, "Settings")
    d.rectangle([73, 0, W, 96], fill=PANEL)
    text(d, (96, 18), "Settings", TEXT, FONT_B)
    tabs = ["Integrations", "AI Summaries", "Activity Log", "Export", "Workforce", "Admin"]
    x = 96
    for i, tab in enumerate(tabs):
        text(d, (x, 66), tab, PRIMARY if i == 4 else MUTED, FONT_S)
        if i == 4:
            d.line([x, 91, x + len(tab) * 9, 91], fill=PRIMARY, width=3)
        x += len(tab) * 11 + 44
    # Workforce tab content
    d.rectangle([73, 96, 413, H], fill=BG)
    d.line([413, 96, 413, H], fill=LINE)
    # Left panel header buttons
    rr(d, [88, 110, 230, 144], 8, PRIMARY)
    text(d, (104, 118), "+ New contact", BG, FONT_S)
    rr(d, [244, 110, 360, 144], 8, BG, LINE)
    text(d, (258, 118), "Import JSON", MUTED, FONT_S)
    rr(d, [88, 152, 190, 182], 8, BG, LINE)
    text(d, (100, 158), "Export JSON", MUTED, FONT_XS)
    rr(d, [198, 152, 290, 182], 8, BG, LINE)
    text(d, (208, 158), "Export CSV", MUTED, FONT_XS)
    d.line([73, 192, 413, 192], fill=LINE)
    contacts = [
        ("Alice Smith", "Lead Engineer — Acme"),
        ("Bob Jones", "PM — Internal"),
        ("Carol Wu", "Vendor — Supplies"),
        ("David Park", "Advisor"),
    ]
    cy = 204
    for i, (name, sub) in enumerate(contacts):
        if i == 0:
            d.rectangle([73, cy - 4, 413, cy + 56], fill="#17233A")
            d.rectangle([73, cy - 4, 76, cy + 56], fill=PRIMARY)
        initial = name[0]
        rr(d, [92, cy + 4, 128, cy + 44], 20, PRIMARY + "23")
        text(d, (101, cy + 12), initial, PRIMARY, FONT_B)
        text(d, (140, cy + 4), name, PRIMARY if i == 0 else TEXT, FONT_S)
        text(d, (140, cy + 28), sub, DIM, FONT_XS)
        cy += 64
    # Right panel — contact detail
    text(d, (444, 112), "Alice Smith", TEXT, FONT_H)
    text(d, (444, 156), "Lead Engineer  ·  Acme", MUTED, FONT_S)
    d.line([430, 190, 1178, 190], fill=LINE)
    fields = [
        ("Phone", "555-0100"),
        ("Alternate", "555-0101"),
        ("Email", "alice@acme.example"),
        ("Website", "acme.example"),
        ("Notes", "Primary technical contact for integration work."),
    ]
    fy = 204
    for label, value in fields:
        text(d, (444, fy), label, DIM, FONT_XS)
        text(d, (590, fy), value, TEXT, FONT_S)
        fy += 32
    d.line([430, fy + 8, 1178, fy + 8], fill=LINE)
    text(d, (444, fy + 20), "Responsibilities", TEXT, FONT_B)
    rr(d, [430, fy + 50, 1178, fy + 90], 8, PANEL, LINE)
    text(d, (450, fy + 62), "Projects owned (1)", MUTED, FONT_S)
    text(d, (1150, fy + 62), "›", DIM, FONT_B)
    rr(d, [430, fy + 100, 1178, fy + 140], 8, PANEL, LINE)
    text(d, (450, fy + 112), "Project roles (2)", MUTED, FONT_S)
    text(d, (1150, fy + 112), "›", DIM, FONT_B)
    rr(d, [430, fy + 150, 1178, fy + 190], 8, PANEL, LINE)
    text(d, (450, fy + 162), "Work items owned (3)", MUTED, FONT_S)
    text(d, (1150, fy + 162), "›", DIM, FONT_B)
    im.save(OUT / "settings.png")


if __name__ == "__main__":
    make_today()
    make_projects()
    make_operations()
    make_library()
    make_settings()
    print("Generated README screenshots in docs/screenshots/")
