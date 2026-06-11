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
    rr(d, [18, 14, 54, 50], 10, BG, LINE)
    text(d, (19, 56), "ATLAS", PRIMARY, FONT_XS)
    items = [("Today", "T"), ("Projects", "P"), ("Library", "L")]
    y = 104
    for name, glyph in items:
        is_selected = name == selected
        if is_selected:
            rr(d, [10, y - 8, 62, y + 48], 18, "#1B2B4A")
        text(d, (31, y), glyph, PRIMARY if is_selected else MUTED, FONT_B)
        text(d, (12, y + 28), name, PRIMARY if is_selected else MUTED, FONT_XS)
        y += 78
    settings_selected = selected == "Settings"
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
    width = len(label) * 8 + 18
    rr(d, [x, y, x + width, y + 24], 4, color + "33", color)
    text(d, (x + 9, y + 4), label, color, FONT_XS)
    return x + width + 10


def make_today():
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    nav(d, "Today")
    appbar(d, "Today", "Thu Jun 11")
    metric(d, 96, "Doing", 2, AMBER)
    metric(d, 376, "Overdue", 1, RED)
    metric(d, 656, "Blocked", 1, PURPLE)
    metric(d, 936, "Total", 6, TEXT)
    sections = [
        (
            "Doing Now",
            AMBER,
            [
                ("Finalize README screenshots", "Use clean demo state; keep private data out", "HIGH", "6/11", False),
                ("Push current source to GitHub", "Remote: ppeck1/project-atlas", "URGENT", "6/11", True),
            ],
        ),
        (
            "Overdue",
            RED,
            [("Review migration notes", "Confirm schema v8 and repair-on-open behavior", "HIGH", "6/10", False)],
        ),
        (
            "Phone / Follow-up",
            BLUE,
            [("Send today list to phone", "Telegram outbound queue demo", "NORMAL", "", True)],
        ),
        (
            "High Priority",
            ORANGE,
            [("Document local AI review flow", "Ollama drafts are saved only after review", "HIGH", "", False)],
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
            if prio != "NORMAL":
                pill(d, 1040, y + 14, prio, ORANGE if prio == "HIGH" else RED)
            if due:
                text(d, (1105, y + 42), due, ORANGE if due == "6/11" else RED, FONT_S)
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
    rr(d, [1040, 17, 1178, 50], 8, PRIMARY)
    text(d, (1060, 24), "New project", BG, FONT_S)
    rows = [
        ("Project Atlas README Refresh", "Bring docs and GitHub up to current state", "active", "ship", True),
        ("Local AI Review Loop", "Human-in-the-loop summaries and drafts", "active", "test", False),
        ("Document Library", "Import local files and link them to work items", "active", "build", False),
        ("Telegram Outbox", "Outbound task list with HTML escaping", "paused", "stabilize", False),
    ]
    y = 96
    for title, desc, status, phase, active in rows:
        rr(d, [96, y, 1184, y + 92], 14, PANEL, PRIMARY if active else LINE, 2 if active else 1)
        rr(d, [116, y + 18, 154, y + 56], 10, "#1B2B4A" if active else "#243040")
        text(d, (128, y + 26), "P", PRIMARY if active else MUTED, FONT_B)
        text(d, (174, y + 14), title, TEXT, FONT_B)
        text(d, (174, y + 43), desc, MUTED, FONT_S)
        x = pill(d, 174, y + 66, status, GREEN if status == "active" else ORANGE)
        pill(d, x, y + 66, phase, BLUE if phase in ("test", "build") else GREEN)
        if active:
            pill(d, 1090, y + 18, "ACTIVE", PRIMARY)
        text(d, (1156, y + 34), ">", DIM, FONT_B)
        y += 106
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
    text(d, (1000, 23), "5 items", DIM, FONT_S)
    rr(d, [1084, 14, 1178, 48], 8, PRIMARY)
    text(d, (1106, 22), "Import", BG, FONT_S)
    d.line([73, 62, W, 62], fill=LINE)
    d.rectangle([73, 63, 393, H], fill=BG)
    d.line([393, 63, 393, H], fill=LINE)
    entries = [
        ("README current-state notes", "AI Draft", GREEN),
        ("BOH visualization spec", "TXT", MUTED),
        ("Launch checklist", "MD", MUTED),
        ("Review summary", "AI Draft", GREEN),
    ]
    y = 82
    for i, (title, kind, color) in enumerate(entries):
        if i == 0:
            d.rectangle([73, y - 6, 393, y + 62], fill="#17233A")
            d.rectangle([73, y - 6, 76, y + 62], fill=PRIMARY)
        text(d, (96, y), title, PRIMARY if i == 0 else TEXT, FONT_S)
        text(d, (96, y + 26), "Project Atlas", DIM, FONT_XS)
        pill(d, 294, y + 4, kind, color)
        y += 72
    text(d, (430, 104), "README current-state notes", TEXT, FONT_H)
    pill(d, 430, 150, "AI Draft - today_summary", GREEN)
    text(d, (430, 188), "Jun 11, 2026", MUTED, FONT_S)
    rr(d, [430, 232, 1178, 690], 8, PANEL, LINE)
    body = [
        "Current project state:",
        "- Local-first Flutter desktop app with SQLite/Drift schema v8.",
        "- Primary nav: Today, Projects, Library, Settings.",
        "- Legacy deep links remain for Work, Review, Export, Governance, and Log.",
        "- Ollama output is advisory and saved only after human review.",
        "- Telegram is outbound only and records outbox attempts.",
    ]
    yy = 260
    for line in body:
        text(d, (460, yy), line, TEXT if yy == 260 else MUTED, FONT_B if yy == 260 else FONT_S)
        yy += 38
    im.save(OUT / "library.png")


def make_settings():
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    nav(d, "Settings")
    d.rectangle([73, 0, W, 96], fill=PANEL)
    text(d, (96, 18), "Settings", TEXT, FONT_B)
    tabs = ["Integrations", "Activity Log", "Export", "Workforce", "Admin"]
    x = 96
    for i, tab in enumerate(tabs):
        text(d, (x, 66), tab, PRIMARY if i == 0 else MUTED, FONT_S)
        if i == 0:
            d.line([x, 91, x + 88, 91], fill=PRIMARY, width=3)
        x += len(tab) * 11 + 44
    text(d, (104, 134), "Telegram", TEXT, FONT_B)
    text(d, (104, 164), "Outbound only - sends task list to your phone.", MUTED, FONT_S)
    rr(d, [104, 206, 1160, 252], 6, BG, LINE)
    text(d, (126, 219), "Enable Telegram sending", TEXT, FONT_S)
    text(d, (1090, 219), "off", DIM, FONT_S)
    rr(d, [104, 276, 1160, 330], 6, BG, LINE)
    text(d, (126, 288), "Bot Token", MUTED, FONT_XS)
    text(d, (126, 306), "1234567890:ABCdef...", DIM, FONT_S)
    rr(d, [104, 350, 1160, 404], 6, BG, LINE)
    text(d, (126, 362), "Chat ID", MUTED, FONT_XS)
    text(d, (126, 380), "-100123456789", DIM, FONT_S)
    rr(d, [104, 430, 250, 466], 8, BG, LINE)
    text(d, (126, 439), "Test connection", MUTED, FONT_S)
    d.line([104, 496, 1160, 496], fill=LINE)
    text(d, (104, 532), "Ollama (local AI)", TEXT, FONT_B)
    text(d, (104, 562), "Used for summarization and drafts. Output always shown for review.", MUTED, FONT_S)
    rr(d, [104, 604, 1160, 658], 6, BG, LINE)
    text(d, (126, 616), "Ollama host", MUTED, FONT_XS)
    text(d, (126, 634), "http://localhost:11434", DIM, FONT_S)
    rr(d, [104, 678, 1160, 732], 6, BG, LINE)
    text(d, (126, 690), "Model name", MUTED, FONT_XS)
    text(d, (126, 708), "mistral", DIM, FONT_S)
    im.save(OUT / "settings.png")


if __name__ == "__main__":
    make_today()
    make_projects()
    make_library()
    make_settings()
    print("Generated README screenshots in docs/screenshots")
