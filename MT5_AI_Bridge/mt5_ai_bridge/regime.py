"""Deterministic market-regime classification — no AI involved.

Computes trend strength (ADX) and volatility level (ATR percentile) from
recent candles, purely with indicator math. This is the "market condition"
label every signal and trade gets tagged with, so performance can later be
broken down by regime instead of lumped together.
"""

from __future__ import annotations

import pandas as pd


def compute_regime(candles: list[dict], adx_period: int = 14, atr_period: int = 14,
                    adx_trend_threshold: float = 25.0) -> dict:
    if len(candles) < max(adx_period, atr_period) * 2:
        return {"label": "unknown", "trend": "unknown", "volatility": "unknown",
                "adx": None, "atr": None, "atr_percentile": None}

    df = pd.DataFrame(candles)
    high, low, close = df["high"], df["low"], df["close"]
    prev_close = close.shift(1)

    tr = pd.concat([high - low, (high - prev_close).abs(), (low - prev_close).abs()], axis=1).max(axis=1)
    atr = tr.rolling(atr_period).mean()

    up_move = high.diff()
    down_move = -low.diff()
    plus_dm = up_move.where((up_move > down_move) & (up_move > 0), 0.0)
    minus_dm = down_move.where((down_move > up_move) & (down_move > 0), 0.0)
    tr_sum = tr.rolling(adx_period).sum()
    plus_di = 100 * plus_dm.rolling(adx_period).sum() / tr_sum
    minus_di = 100 * minus_dm.rolling(adx_period).sum() / tr_sum
    di_sum = (plus_di + minus_di).replace(0, pd.NA)
    dx = 100 * (plus_di - minus_di).abs() / di_sum
    adx = dx.rolling(adx_period).mean()

    latest_adx = adx.iloc[-1]
    latest_atr = atr.iloc[-1]
    atr_history = atr.dropna()

    if pd.isna(latest_adx) or pd.isna(latest_atr) or len(atr_history) == 0:
        return {"label": "unknown", "trend": "unknown", "volatility": "unknown",
                "adx": None, "atr": None, "atr_percentile": None}

    atr_percentile = float((atr_history <= latest_atr).mean() * 100)
    trend = "trending" if latest_adx >= adx_trend_threshold else "ranging"
    volatility = "high" if atr_percentile >= 60 else ("low" if atr_percentile <= 40 else "normal")

    return {
        "label": f"{trend}-{volatility}vol",
        "trend": trend,
        "volatility": volatility,
        "adx": round(float(latest_adx), 1),
        "atr": round(float(latest_atr), 5),
        "atr_percentile": round(atr_percentile, 1),
    }
