"""Deterministic ICT/SMC structure detection, ported from the MQL5
MMBM_LiquiditySweep_EA so the bridge can hand Claude the *same* computed
features (HTF bias, liquidity sweep, market-structure shift, fair value gap,
suggested entry/SL/TP) the EA draws on the chart — instead of asking the model
to re-derive all of that from raw OHLC numbers every call.

Candles in are ascending (oldest first, index -1 = most recent), matching
mt5.copy_rates ordering. Internally we reverse to a newest-first "series" so the
index math mirrors the EA's ArraySetAsSeries(true) arrays one-to-one.
"""

from __future__ import annotations

import math

# Defaults mirror the EA's inputs.
MAX_BARS_AFTER_SWEEP = 25
MAX_BARS_FOR_FVG_SEARCH = 15


def _digits_from_point(point: float) -> int:
    if point <= 0:
        return 5
    return max(0, min(8, round(-math.log10(point))))


def _is_swing_high(r: list[dict], idx: int, k: int) -> bool:
    n = len(r)
    for j in range(1, k + 1):
        if idx - j < 0 or idx + j >= n:
            return False
        if r[idx - j]["high"] >= r[idx]["high"] or r[idx + j]["high"] >= r[idx]["high"]:
            return False
    return True


def _is_swing_low(r: list[dict], idx: int, k: int) -> bool:
    n = len(r)
    for j in range(1, k + 1):
        if idx - j < 0 or idx + j >= n:
            return False
        if r[idx - j]["low"] <= r[idx]["low"] or r[idx + j]["low"] <= r[idx]["low"]:
            return False
    return True


def _find_liquidity_sweep(r: list[dict], total: int, bullish: bool, k: int):
    """A wick pierces a prior swing (low for bullish, high for bearish) and the
    candle closes back inside. Returns the most recent such sweep, or None."""
    for i in range(k + 1, total - k):
        if bullish and _is_swing_low(r, i, k):
            level = r[i]["low"]
            for j in range(i - k - 1, -1, -1):
                if r[j]["low"] < level and r[j]["close"] > level:
                    return {"sweep_idx": j, "sweep_price": r[j]["low"],
                            "liquidity_level": level, "liquidity_time": r[i]["time"]}
        if not bullish and _is_swing_high(r, i, k):
            level = r[i]["high"]
            for j in range(i - k - 1, -1, -1):
                if r[j]["high"] > level and r[j]["close"] < level:
                    return {"sweep_idx": j, "sweep_price": r[j]["high"],
                            "liquidity_level": level, "liquidity_time": r[i]["time"]}
    return None


def _find_mss(r: list[dict], bullish: bool, sweep_idx: int, k: int):
    """Most recent opposing minor swing formed after the sweep, then a close
    beyond it (the structure shift). Returns {mss_idx, mss_level} or None."""
    ref_level = None
    for i in range(sweep_idx - k, k - 1, -1):
        if bullish and _is_swing_high(r, i, k):
            ref_level = r[i]["high"]
            break
        if not bullish and _is_swing_low(r, i, k):
            ref_level = r[i]["low"]
            break
    if ref_level is None:
        return None
    for j in range(sweep_idx - 1, -1, -1):
        if bullish and r[j]["close"] > ref_level:
            return {"mss_idx": j, "mss_level": ref_level}
        if not bullish and r[j]["close"] < ref_level:
            return {"mss_idx": j, "mss_level": ref_level}
    return None


def _find_entry_fvg(r: list[dict], sweep_idx: int, mss_idx: int, bullish: bool,
                    point: float, min_fvg_points: float):
    """3-candle imbalance inside the sweep->MSS impulse leg, nearest to the MSS
    bar first. Returns {fvg_high, fvg_low} or None."""
    n = len(r)
    min_size = min_fvg_points * point
    search_from = min(sweep_idx, mss_idx + MAX_BARS_FOR_FVG_SEARCH)
    for i in range(mss_idx + 1, search_from):
        if i - 1 < 0 or i + 1 >= n:
            continue
        if bullish:
            gap_low = r[i - 1]["low"]
            gap_high = r[i + 1]["high"]
        else:
            gap_high = r[i - 1]["high"]
            gap_low = r[i + 1]["low"]
        if gap_low > gap_high and (gap_low - gap_high) >= min_size:
            return {"fvg_high": gap_low, "fvg_low": gap_high}
    return None


def _find_liquidity_target(r: list[dict], total: int, bullish: bool, entry: float, k: int):
    """Next external liquidity beyond entry — the draw-on-liquidity TP target."""
    for i in range(k, total - k):
        if bullish and _is_swing_high(r, i, k) and r[i]["high"] > entry:
            return r[i]["high"]
        if not bullish and _is_swing_low(r, i, k) and r[i]["low"] < entry:
            return r[i]["low"]
    return None


def _compute_entry_sl(bullish: bool, fvg_high: float, fvg_low: float,
                      sweep_extreme: float, point: float, entry_midpoint: bool,
                      sweep_buffer_points: float):
    if entry_midpoint:
        entry = (fvg_high + fvg_low) / 2.0
    else:
        entry = fvg_low if bullish else fvg_high
    sl = (sweep_extreme - sweep_buffer_points * point) if bullish \
        else (sweep_extreme + sweep_buffer_points * point)
    return entry, sl


def compute_htf_bias(htf_candles: list[dict], k: int) -> tuple[bool, bool]:
    """HH/HL -> bullish only, LH/LL -> bearish only, mixed -> both allowed."""
    r = list(reversed(htf_candles))
    n = len(r)
    if n < 2 * k + 10:
        return True, True
    highs: list[float] = []
    lows: list[float] = []
    for i in range(n - k - 1, k - 1, -1):
        if _is_swing_high(r, i, k):
            highs.append(r[i]["high"])
        if _is_swing_low(r, i, k):
            lows.append(r[i]["low"])
        if len(highs) >= 2 and len(lows) >= 2:
            break
    if len(highs) < 2 or len(lows) < 2:
        return True, True
    if highs[0] > highs[1] and lows[0] > lows[1]:
        return True, False
    if highs[0] < highs[1] and lows[0] < lows[1]:
        return False, True
    return True, True


def _nearest_swings(series: list[dict], total: int, k: int, digits: int) -> dict:
    """Nearest swing high above and swing low below — the obvious liquidity
    pools price is drawing toward, regardless of any sweep/MSS setup."""
    high = None
    low = None
    for i in range(k, total - k):
        if high is None and _is_swing_high(series, i, k):
            high = round(series[i]["high"], digits)
        if low is None and _is_swing_low(series, i, k):
            low = round(series[i]["low"], digits)
        if high is not None and low is not None:
            break
    return {"nearest_swing_high": high, "nearest_swing_low": low}


def _premium_discount(candles: list[dict], digits: int) -> dict:
    """Where current price sits in the recent dealing range — a core ICT
    concept (sell in premium, buy in discount) the EA doesn't expose."""
    highs = [c["high"] for c in candles]
    lows = [c["low"] for c in candles]
    range_high = max(highs)
    range_low = min(lows)
    span = range_high - range_low
    close = candles[-1]["close"]
    equilibrium = (range_high + range_low) / 2.0
    if span <= 0:
        zone = "unknown"
        pct = None
    else:
        pct = (close - range_low) / span * 100.0
        if pct >= 60:
            zone = "premium"
        elif pct <= 40:
            zone = "discount"
        else:
            zone = "equilibrium"
    return {
        "range_high": round(range_high, digits),
        "range_low": round(range_low, digits),
        "equilibrium": round(equilibrium, digits),
        "price_zone": zone,
        "range_position_pct": round(pct, 1) if pct is not None else None,
    }


def _detect_setup(series: list[dict], total: int, bullish: bool, point: float,
                  k: int, min_fvg_points: float, sweep_buffer_points: float,
                  entry_midpoint: bool, fallback_rr: float):
    digits = _digits_from_point(point)
    sweep = _find_liquidity_sweep(series, total, bullish, k)
    if sweep is None or sweep["sweep_idx"] > MAX_BARS_AFTER_SWEEP:
        return None

    out: dict = {
        "stage": "sweep_only",
        "swept_level": round(sweep["liquidity_level"], digits),
        "sweep_extreme": round(sweep["sweep_price"], digits),
        "bars_since_sweep": sweep["sweep_idx"],
    }

    mss = _find_mss(series, bullish, sweep["sweep_idx"], k)
    if mss is None:
        return out
    out["stage"] = "mss_confirmed"
    out["mss_level"] = round(mss["mss_level"], digits)

    fvg = _find_entry_fvg(series, sweep["sweep_idx"], mss["mss_idx"], bullish,
                          point, min_fvg_points)
    if fvg is None:
        return out
    out["stage"] = "ready"
    out["fvg_high"] = round(fvg["fvg_high"], digits)
    out["fvg_low"] = round(fvg["fvg_low"], digits)

    entry, sl = _compute_entry_sl(bullish, fvg["fvg_high"], fvg["fvg_low"],
                                  sweep["sweep_price"], point, entry_midpoint,
                                  sweep_buffer_points)
    sl_dist = abs(entry - sl)
    target = _find_liquidity_target(series, total, bullish, entry, k)
    if target is not None:
        tp = target
    else:
        tp = entry + sl_dist * fallback_rr if bullish else entry - sl_dist * fallback_rr

    out["suggested_entry"] = round(entry, digits)
    out["suggested_sl"] = round(sl, digits)
    out["suggested_tp"] = round(tp, digits)
    out["rr"] = round(abs(tp - entry) / sl_dist, 2) if sl_dist > 0 else None
    return out


def compute_ict_features(candles: list[dict], htf_candles: list[dict] | None,
                         point: float, *, swing_lr: int = 3,
                         min_fvg_points: float = 30.0, sweep_buffer_points: float = 20.0,
                         entry_midpoint: bool = True, fallback_rr: float = 2.0,
                         require_htf_bias: bool = True) -> dict:
    """Top-level: returns HTF bias plus the current bullish/bearish setup state
    (sweep_only / mss_confirmed / ready, with levels) for feeding to the AI."""
    series = list(reversed(candles))
    total = len(series)
    k = swing_lr
    if total < 2 * k + 10:
        return {"available": False, "reason": "not enough candles"}

    if require_htf_bias and htf_candles:
        bull_bias, bear_bias = compute_htf_bias(htf_candles, k)
    else:
        bull_bias = bear_bias = True

    if bull_bias and not bear_bias:
        bias_label = "bullish"
    elif bear_bias and not bull_bias:
        bias_label = "bearish"
    else:
        bias_label = "neutral"

    digits = _digits_from_point(point)
    result: dict = {
        "available": True,
        "htf_bias": bias_label,
        "context": {**_nearest_swings(series, total, k, digits),
                    **_premium_discount(candles, digits)},
        "bullish_setup": None,
        "bearish_setup": None,
    }

    if bull_bias:
        result["bullish_setup"] = _detect_setup(
            series, total, True, point, k, min_fvg_points, sweep_buffer_points,
            entry_midpoint, fallback_rr)
    if bear_bias:
        result["bearish_setup"] = _detect_setup(
            series, total, False, point, k, min_fvg_points, sweep_buffer_points,
            entry_midpoint, fallback_rr)

    return result
