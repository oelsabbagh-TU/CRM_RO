"""Regenerate 2-zone-only figures from the 2-zone settlement events CSV.
The figures already in Results/Figures/ include 3-zone data (A->C contract);
this script outputs clean 2-zone-only versions that just show the A->B contract
under FBMC vs NTC."""
import csv
from pathlib import Path
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches

ROOT = Path(__file__).parent
EVENTS = ROOT / "Results" / "ro_settlement_events_K500.csv"
OUT_DIR = ROOT / "Results" / "Figures"

# Read events
rows = []
with open(EVENTS, encoding="utf-8") as f:
    reader = csv.DictReader(f, delimiter=";")
    for r in reader:
        rows.append(r)

# Filter Cat > 0 events (scarcity events)
events = [r for r in rows if int(r["Category"]) > 0]

ORANGE = "#C15A2E"
TEAL = "#2E6F7A"
INK = "#111111"
MUTED = "#666666"

# === Figure 1: per-timestep hedge shortfall, 2-zone NTC, A->B only ===
# (FBMC ≡ NTC in two zones; the existing FBMC-tagged data is stale and dropped here.)
fig, ax = plt.subplots(figsize=(8, 4.5))
sub = [r for r in events if r["Design"] == "NTC"]
ts = [int(r["Timestep"]) for r in sub]
delta = [float(r["HedgeShortfall_EUR_per_h"]) / 1e6 for r in sub]
weights = [float(r["Weight_h"]) for r in sub]
ax.axhline(0, color=INK, lw=0.7)
ax.scatter(ts, delta, s=[max(w * 30, 60) for w in weights],
           color=ORANGE, alpha=0.85, edgecolor="white", linewidth=0.8)
for t, d in zip(ts, delta):
    sign = "+" if d > 0 else ""
    ax.annotate(f"{sign}{d:.3f} M€/h", (t, d),
                textcoords="offset points", xytext=(10, 6),
                fontsize=10, color=INK)
ax.set_title("Per-timestep hedge shortfall  (2-zone, NTC, A→B, K = 150 €/MWh)",
             fontsize=12, color=INK, pad=12)
ax.set_xlabel("Timestep", fontsize=10, color=INK)
ax.set_ylabel("Hedge shortfall  Δ  [M€/h]", fontsize=10, color=INK)
ax.set_xlim(0, 25)
ax.grid(True, ls=":", alpha=0.5)
ax.spines["top"].set_visible(False)
ax.spines["right"].set_visible(False)
plt.tight_layout()
out1 = OUT_DIR / "ro_2zone_event_shortfall_K500.png"
plt.savefig(out1, dpi=200, bbox_inches="tight")
print(f"Saved: {out1}")
plt.close()

# === Figure 2: side-by-side breakdown for both NTC scarcity events ===
ntc_events = sorted([r for r in events if r["Design"] == "NTC"],
                    key=lambda r: int(r["Timestep"]))
if not ntc_events:
    raise RuntimeError("No NTC scarcity events found")

fig, axes = plt.subplots(1, len(ntc_events), figsize=(5.5 * len(ntc_events), 4.7),
                          sharey=True)
if len(ntc_events) == 1:
    axes = [axes]
all_values = []
for ev in ntc_events:
    all_values.extend([
        float(ev["HedgeRequirement_EUR_per_h"]) / 1e6,
        float(ev["RO_Repayment_EUR_per_h"]) / 1e6,
        float(ev["HedgeShortfall_EUR_per_h"]) / 1e6,
        float(ev["CR_Alloc_EUR_per_h"]) / 1e6,
    ])
y_max = max(max(all_values), 0) * 1.32
y_min = min(min(all_values), 0) * 1.65 if min(all_values) < 0 else 0

labels = ["H", "Πᴿᴼ", "Δ", "CCRS"]
colors = [INK, "#888888", ORANGE, TEAL]
for ax, ev in zip(axes, ntc_events):
    H = float(ev["HedgeRequirement_EUR_per_h"]) / 1e6
    RO = float(ev["RO_Repayment_EUR_per_h"]) / 1e6
    DELTA = float(ev["HedgeShortfall_EUR_per_h"]) / 1e6
    CR = float(ev["CR_Alloc_EUR_per_h"]) / 1e6
    P_imp = float(ev["P_Importer_EUR_per_MWh"])
    P_exp = float(ev["P_Exporter_EUR_per_MWh"])
    K = float(ev["Strike_K_EUR_per_MWh"])
    q = float(ev["Capacity_MW"])
    cat_label = "Cat 2a — generator under-pays" if DELTA > 0 else "Cat 2b — generator over-pays"
    values = [H, RO, DELTA, CR]
    bars = ax.bar(labels, values, color=colors, alpha=0.9,
                  edgecolor="white", linewidth=1.5)
    for bar, v in zip(bars, values):
        offset = 0.035 * (y_max - y_min)
        ha_va = ("center", "bottom") if v >= 0 else ("center", "top")
        y_lab = v + offset if v >= 0 else v - offset
        ax.text(bar.get_x() + bar.get_width() / 2, y_lab,
                f"{v:+.2f}", ha=ha_va[0], va=ha_va[1],
                fontsize=11, color=INK, weight="bold")
    ax.axhline(0, color=INK, lw=0.7)
    ax.set_ylim(y_min, y_max)
    ax.set_title(
        f"Timestep {ev['Timestep']}  ·  {cat_label}\n"
        f"Pᴬ = {P_imp:.0f},  Pᴮ = {P_exp:.0f}  €/MWh   ·   q = {q:.0f} MW",
        fontsize=11, color=INK)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.grid(True, axis="y", ls=":", alpha=0.5)
axes[0].set_ylabel("M€  per hour of the event", fontsize=10, color=INK)
fig.suptitle(f"2-zone NTC, A→B contract, S = {K:.0f} €/MWh   ·   "
             f"both scarcity events of the year",
             fontsize=12, color=INK, y=1.02)
plt.tight_layout()
out2 = OUT_DIR / "ro_2zone_t18_breakdown_K500.png"
plt.savefig(out2, dpi=200, bbox_inches="tight")
print(f"Saved: {out2}")
plt.close()
