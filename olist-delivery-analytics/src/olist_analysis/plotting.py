"""Consistent chart styling and a helper that saves every figure for the README."""
from __future__ import annotations

import matplotlib.pyplot as plt
import seaborn as sns

from .data import FIGURES_DIR

PALETTE = ["#1f4e79", "#2e86ab", "#f18f01", "#c73e1d", "#3b1f2b", "#6a994e", "#a7c957", "#8d99ae"]
ACCENT = "#c73e1d"
BASE = "#1f4e79"


def set_style() -> None:
    sns.set_theme(style="whitegrid", palette=PALETTE)
    plt.rcParams.update({
        "figure.figsize": (10, 5),
        "figure.dpi": 110,
        "axes.titlesize": 13,
        "axes.titleweight": "bold",
        "axes.labelsize": 11,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "savefig.bbox": "tight",
    })


def save(fig, name: str) -> None:
    """Save a figure to reports/figures/<name>.png (used by the README)."""
    FIGURES_DIR.mkdir(parents=True, exist_ok=True)
    fig.savefig(FIGURES_DIR / f"{name}.png", dpi=120)
