# Build the counterfactual slide: generates the two charts from switcher_panel.csv,
# embeds them as base64 into the HTML template (slide_counterfactual_template.html),
# and writes docs/slide_counterfactual.html.
#
# Run from repo root: .venv/Scripts/python.exe analysis/dgr_event_study/make_counterfactual_slide.py

import base64
import io
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

ROOT = Path(__file__).resolve().parents[2]
HERE = ROOT / "analysis" / "dgr_event_study"

p = pd.read_csv(HERE / "switcher_panel.csv")
est = p[~p["is_startup"]].copy()
CPI = {2019: 100.0, 2020: 101.4, 2021: 103.1, 2022: 107.2, 2023: 114.7, 2024: 119.4}
est["donations_real"] = est["donations_and_bequests"] * 100 / est["ais_year"].map(CPI)

# ---- Chart A: staggered cohorts indexed to own pre-endorsement level ----
cohorts = sorted(est["endorsement_fy"].unique())
fig, axes = plt.subplots(1, len(cohorts), figsize=(10.5, 3.2), sharey=True)
for ax, fy in zip(axes, cohorts):
    sub = est[est["endorsement_fy"] == fy]
    med = sub.groupby("ais_year")["donations_real"].median()
    base = med[med.index < fy].mean()
    mi = 100 * med / base
    pre_y = [y for y in mi.index if y < fy]
    post_y = [y for y in mi.index if y >= fy]
    ax.axhline(100, color="#94a3b8", lw=1, ls=":", zorder=1)
    ax.axvspan(fy - 0.5, fy + 0.5, color="#fef3c7", zorder=0)
    ax.axvline(fy, color="#b45309", lw=1, ls="--", zorder=1)
    ax.plot(mi.index, mi.values, color="#cbd5e1", lw=1, zorder=2)
    ax.plot(pre_y, mi.loc[pre_y], "o-", color="#64748b", lw=2, ms=4, zorder=3)
    ax.plot(post_y, mi.loc[post_y], "o-", color="#0f766e", lw=2, ms=4, zorder=3)
    ax.set_title(f"endorsed FY{fy} (n={sub['abn'].nunique()})", fontsize=9)
    ax.set_xticks(list(mi.index))
    ax.set_xticklabels([str(y)[2:] for y in mi.index], fontsize=7.5)
    ax.tick_params(axis="y", labelsize=7.5)
    ax.spines[["top", "right"]].set_visible(False)
    ax.grid(axis="y", alpha=0.25)
axes[0].set_ylabel("median real donations\n(own pre-endorsement = 100)", fontsize=8.5)
fig.tight_layout()
buf_a = io.BytesIO()
fig.savefig(buf_a, format="png", dpi=160, bbox_inches="tight")
plt.close(fig)

# ---- Chart B: slope chart, all established switchers ----
g = pd.DataFrame({
    "pre": est[est["event_year"] < 0].groupby("abn")["donations_real"].mean(),
    "post": est[est["event_year"] >= 1].groupby("abn")["donations_real"].mean(),
}).dropna()
g["growth"] = (g["post"] - g["pre"]) / g["pre"].clip(lower=1)
up = g["post"] > g["pre"]
FLOOR = 100
fig, ax = plt.subplots(figsize=(5.2, 4.6))
for pre_v, post_v, rose in zip(g["pre"].clip(lower=FLOOR), g["post"].clip(lower=FLOOR), up):
    ax.plot([0, 1], [pre_v, post_v], color="#0f766e" if rose else "#b91c1c",
            alpha=0.10, lw=0.8, zorder=1)
mp, mq = g["pre"].median(), g["post"].median()
ax.plot([0, 1], [mp, mq], "o-", color="black", lw=3, ms=8, zorder=3)
ax.annotate(f"median charity\n\\${mp:,.0f} \u2192 \\${mq:,.0f}",
            xy=(0.5, (mp * mq) ** 0.5), xytext=(0.54, mp * 7), fontsize=9.5,
            fontweight="bold", arrowprops=dict(arrowstyle="->", color="black", lw=1.1),
            zorder=4)
ax.set_yscale("log")
ax.set_xticks([0, 1])
ax.set_xticklabels(["BEFORE\nendorsement", "AFTER\nendorsement"], fontsize=9)
ax.set_xlim(-0.1, 1.1)
ax.yaxis.set_major_formatter(plt.FuncFormatter(
    lambda v, _: f"\\${v:,.0f}" if v < 1e6 else f"\\${v/1e6:g}m"))
ax.tick_params(axis="y", labelsize=8)
ax.set_ylabel("annual donations (real FY2019 $, log scale)", fontsize=8.5)
ax.set_title(f"646 charities: {up.mean():.0%} tilt up, {1 - up.mean():.0%} down",
             fontsize=10, loc="left")
ax.spines[["top", "right"]].set_visible(False)
fig.tight_layout()
buf_b = io.BytesIO()
fig.savefig(buf_b, format="png", dpi=160, bbox_inches="tight")
plt.close(fig)

# ---- Also save standalone PNGs for reuse in decks ----
(HERE / "slide_cohorts.png").write_bytes(buf_a.getvalue())
(HERE / "slide_slopes.png").write_bytes(buf_b.getvalue())

# ---- Assemble the HTML slide ----
template = (HERE / "slide_counterfactual_template.html").read_text(encoding="utf-8")
html = (template
        .replace("{{COHORTS_B64}}", base64.b64encode(buf_a.getvalue()).decode())
        .replace("{{SLOPES_B64}}", base64.b64encode(buf_b.getvalue()).decode()))
out = ROOT / "docs" / "slide_counterfactual.html"
out.write_text(html, encoding="utf-8")
print(f"written: {out}")
print(f"median real growth check: {g['growth'].median():+.1%}")
