"""Who is who — originator vs seller vs servicer, and what we can prove.

    uv run python work/data-issues/diagrams/who_is_who.py

Writes who-is-who.png (share) and who-is-who.svg (edit) beside this file.
Figures measured 2026-10-09; see work/dbt/WHO-IS-WHO.md for the queries.

Canvas is 1 unit = 0.1 inch on BOTH axes, so spacing reads the same
horizontally and vertically and columns can be placed by eye.
"""
from pathlib import Path

import matplotlib.patches as mp
import matplotlib.pyplot as plt

HERE = Path(__file__).resolve().parent

INK, INK2, INK3 = "#13181D", "#3C4650", "#6B7784"
RULE, PANEL = "#D7DDE5", "#F7F9FB"
HAVE, HAVE_F = "#0F7A56", "#DEF1E9"   # a real company key
TEXT_, TEXT_F = "#B4440C", "#FBE9DD"  # a name only, no key
GONE = "#8A95A3"                      # nothing we can use
NOTE_F, NOTE_INK = "#EFE9FA", "#4E2A8E"

W, H = 15.6, 11.6
fig, ax = plt.subplots(figsize=(W, H), dpi=140)
fig.patch.set_facecolor("white")
ax.set_xlim(0, W * 10); ax.set_ylim(0, H * 10); ax.axis("off")
ax.set_position([0, 0, 1, 1])


def box(x, y, w, h, label, sub, edge, fill, fs=13):
    ax.add_patch(mp.FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.4,rounding_size=1.2",
                                   linewidth=2.1, edgecolor=edge, facecolor=fill, zorder=3))
    ax.text(x + w / 2, y + h * (0.62 if sub else 0.5), label, ha="center", va="center",
            fontsize=fs, fontweight="bold", color=INK, zorder=4)
    if sub:
        ax.text(x + w / 2, y + h * 0.25, sub, ha="center", va="center",
                fontsize=9, color=INK2, zorder=4)


def arrow(x1, x2, y, dashed=False, color=INK2, lw=2.5):
    ax.annotate("", xy=(x2, y), xytext=(x1, y), zorder=2,
                arrowprops=dict(arrowstyle="-|>,head_width=0.32,head_length=0.66",
                                color=color, linewidth=lw,
                                linestyle=(0, (4, 3)) if dashed else "solid",
                                shrinkA=0, shrinkB=0))


# ── title ────────────────────────────────────────────────────────────────────
ax.text(5, 110, "Who is who — and which of them we can actually prove",
        fontsize=22, fontweight="bold", color=INK, va="top")
ax.text(5, 104.0, "The originator is a proper company key on 84% of our deals, and an unjoinable string on the other 16%.",
        fontsize=13, color=INK2, va="top")
ax.text(5, 99.8, "Measured 2026-10-09 across all 74 deals in DIM_DEAL.",
        fontsize=10, color=INK3, va="top", style="italic")

# legend, on its own line so it cannot collide with the heading
lx = 5
for col, lab in [(HAVE, "a real company key"), (TEXT_, "a name only — no key"), (GONE, "nothing we can use")]:
    ax.add_patch(mp.Rectangle((lx, 94.2), 2.6, 2.0, facecolor=col, edgecolor="none"))
    ax.text(lx + 3.8, 95.2, lab, fontsize=9.6, color=INK2, va="center")
    lx += len(lab) * 1.62 + 10

# ── the three roles ──────────────────────────────────────────────────────────
for x, head, sub in [(5, "ORIGINATOR", "the bank that made the loan"),
                     (62, "SELLER", "whoever sold it to us"),
                     (112, "SERVICER", "whoever collects it")]:
    ax.text(x, 88.6, head, fontsize=12, fontweight="bold", color=INK3, va="top")
    ax.text(x, 85.4, sub, fontsize=9.8, color=INK3, va="top")
arrow(48, 58, 87.1, color=INK3, lw=1.5)
arrow(92, 108, 87.1, color=INK3, lw=1.5)
ax.plot([5, 151], [81.5, 81.5], color=RULE, lw=1.2)

# ── case A ───────────────────────────────────────────────────────────────────
ax.add_patch(mp.Rectangle((5, 58.5), 146, 21.0, facecolor=PANEL, edgecolor=RULE, lw=1))
ax.text(8, 77.4, "62 of 74 deals", fontsize=13, fontweight="bold", color=HAVE, va="top")
ax.text(30, 77.4, "·   WE BOUGHT DIRECT FROM THE BANK", fontsize=13, fontweight="bold",
        color=HAVE, va="top")
box(9, 65.0, 30, 8.6, "BANK", "made the loan", HAVE, HAVE_F)
arrow(41, 60, 69.3)
box(62, 65.0, 26, 8.6, "BROCC", None, HAVE, HAVE_F)
ax.text(50.5, 74.2, "one hop", ha="center", fontsize=10, color=INK2, fontweight="bold")
ax.text(50.5, 66.6, "Atlas  seller_id  ✓", ha="center", fontsize=9.8, color=HAVE,
        fontweight="bold", family="monospace")
ax.text(94, 73.6, "Originator and seller are the SAME company.", fontsize=10.6,
        color=INK, va="top", fontweight="bold")
ax.text(94, 69.8, "Already in the warehouse as DIM_DEAL.SELLER_NAME.", fontsize=9.6,
        color=INK3, va="top")
ax.text(9, 62.4, "Serviced by Intrum on 39 of them, Massey on 2, nothing yet on 21 — so “Intrum-serviced” is not “Intrum-sold”.",
        fontsize=9.8, color=INK3, va="top")

# ── case B ───────────────────────────────────────────────────────────────────
ax.add_patch(mp.Rectangle((5, 31.5), 146, 24.0, facecolor=PANEL, edgecolor=RULE, lw=1))
ax.text(8, 53.4, "12 of 74 deals", fontsize=13, fontweight="bold", color=TEXT_, va="top")
ax.text(30, 53.4, "·   INTRUM BOUGHT IT FIRST, THEN SOLD TO US", fontsize=13,
        fontweight="bold", color=TEXT_, va="top")
box(9, 40.6, 26, 8.6, "BANK", "made the loan", TEXT_, TEXT_F)
arrow(37, 54, 44.9, dashed=True, color=TEXT_)
box(56, 40.6, 26, 8.6, "INTRUM", "bought it", INK3, "white")
arrow(84, 101, 44.9, color=HAVE)
box(103, 40.6, 26, 8.6, "BROCC", None, HAVE, HAVE_F)
ax.text(45.5, 50.0, "hop 1", ha="center", fontsize=10, color=TEXT_, fontweight="bold")
ax.text(45.5, 38.0, "PAM.SELLER_NAME", ha="center", fontsize=9, color=TEXT_, family="monospace")
ax.text(45.5, 35.6, "free text · no id", ha="center", fontsize=9, color=TEXT_, family="monospace")
ax.text(92.5, 50.0, "hop 2", ha="center", fontsize=10, color=HAVE, fontweight="bold")
ax.text(92.5, 37.6, "Atlas  seller_id  ✓", ha="center", fontsize=9.4, color=HAVE,
        fontweight="bold", family="monospace")
ax.text(133, 47.0, "✗  nothing before", fontsize=10.4, color=GONE, fontweight="bold", va="top")
ax.text(133, 43.8, "hop 1 is observable", fontsize=10.4, color=GONE, fontweight="bold", va="top")
ax.text(9, 34.4, "PAM names “whoever Intrum bought from” — which may not be the bank. The six CAT fields that would say are 100% empty on all 1,156,769 PT cases.",
        fontsize=9.8, color=INK3, va="top")

# ── what each role carries ───────────────────────────────────────────────────
ax.plot([5, 151], [28.0, 28.0], color=RULE, lw=1.2)
ax.text(5, 26.2, "WHAT EACH ROLE ACTUALLY CARRIES", fontsize=10.6, fontweight="bold",
        color=INK3, va="top")
rows = [
    ("Seller — sold to us",   "Atlas seller_id",                 "key + name + address",   HAVE,  "reaches DIM_DEAL today"),
    ("Servicer — contracted", "Atlas batch_segment.servicer_id", "key + name + address",   HAVE,  "in staging, read by nothing"),
    ("Originator — the bank", "PAM SELLER_NAME",                 "a name, no key",         TEXT_, "1,360 names / 1,348 once cased"),
    ("Agency — appointed",    "CAT external_collector_id",       "a bare number, no name", GONE,  "190 now, 261 ever seen"),
]
y = 21.0
for role, field, carries, col, note in rows:
    ax.add_patch(mp.Rectangle((5, y - 0.7), 1.3, 2.4, facecolor=col, edgecolor="none"))
    ax.text(8.5, y + 0.5, role,    fontsize=10,  fontweight="bold", color=INK,  va="center")
    ax.text(42,  y + 0.5, field,   fontsize=8.8, color=INK2, va="center", family="monospace")
    ax.text(85,  y + 0.5, carries, fontsize=9.6, color=col,  va="center", fontweight="bold")
    ax.text(116, y + 0.5, note,    fontsize=9,   color=INK3, va="center")
    y -= 3.4

# ── conclusion ───────────────────────────────────────────────────────────────
ax.add_patch(mp.FancyBboxPatch((5, 1.5), 146, 6.2, boxstyle="round,pad=0.4,rounding_size=1.0",
                               linewidth=0, facecolor=NOTE_F))
ax.text(8, 4.6, "One company table, not two.", fontsize=11.6, fontweight="bold",
        color=NOTE_INK, va="center")
ax.text(44, 5.9, "Atlas companies_company is only id + name + address, and the role comes from whichever key points at it —",
        fontsize=9.6, color=NOTE_INK, va="center")
ax.text(44, 3.2, "so dim_servicer and dim_originator would be identical columns.  Split the ORIGINATOR out instead: it is not an Atlas company at all.",
        fontsize=9.6, color=NOTE_INK, va="center")

for ext in ("png", "svg"):
    fig.savefig(HERE / f"who-is-who.{ext}", bbox_inches="tight", pad_inches=0.3,
                facecolor="white", **({"dpi": 170} if ext == "png" else {}))
print("wrote who-is-who.png and who-is-who.svg")
