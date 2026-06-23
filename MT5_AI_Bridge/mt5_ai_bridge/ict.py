"""Deterministic ICT/SMC structure detection, originally ported from the MQL5
MMBM_LiquiditySweep_EA and since expanded into a small *suite* of named ICT
strategy detectors. Instead of asking the model to eyeball 200 rows of OHLC and
re-derive structure every call, the bridge computes the structure in code and
hands Claude a list of detected setups — each tagged with which strategy found
it — plus dealing-range context (HTF bias, premium/discount, liquidity).

Strategies detected (each evaluated for both long and short every call):
- liquidity_sweep_mss : sweep of swing liquidity -> market-structure shift ->
                        fair-value-gap entry (the original EA model; reversal).
- order_block         : last opposing candle before a break of structure;
                        entry on the retrace into that order block.
- fair_value_gap      : a standalone unfilled 3-candle imbalance; entry on the
                        retrace into the gap.
- breaker_block       : an order block that failed (price swept it and shifted
                        structure the other way); entry on the retest.
- turtle_soup         : a false breakout of the prior N-bar range extreme that
                        closes back inside (a liquidity grab); reversal.
- optimal_trade_entry : the 0.62-0.79 fib retracement zone of the most recent
                        impulse leg (ICT "OTE").

Candles in are ascending (oldest first, index -1 = most recent), matching
mt5.copy_rates ordering. Internally we reverse to a newest-first "series" so the
index math mirrors the EA's ArraySetAsSeries(true) arrays one-to-one.
"""

from __future__ import annotations

import math

# Defaults mirror the EA's inputs.
MAX_BARS_AFTER_SWEEP = 25
MAX_BARS_FOR_FVG_SEARCH = 15
FVG_SCAN_BARS = 60          # how far back a standalone FVG may be and still count
TURTLE_LOOKBACK = 20        # range window for the turtle-soup false-break check

STRATEGIES = (
    "liquidity_sweep_mss",
    "order_block",
    "fair_value_gap",
    "breaker_block",
    "turtle_soup",
    "optimal_trade_entry",
)


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


def _recent_swing(r: list[dict], total: int, k: int, want_high: bool):
    """Index of the most recent confirmed swing high/low, or None."""
    for i in range(k, total - k):
        if want_high and _is_swing_high(r, i, k):
            return i
        if not want_high and _is_swing_low(r, i, k):
            return i
    return None


def _finalize(entry: float, sl: float, tp: float, digits: int) -> dict:
    sl_dist = abs(entry - sl)
    return {
        "suggested_entry": round(entry, digits),
        "suggested_sl": round(sl, digits),
        "suggested_tp": round(tp, digits),
        "rr": round(abs(tp - entry) / sl_dist, 2) if sl_dist > 0 else None,
    }


def _stage_from_zone(series: list[dict], zone_lo: float, zone_hi: float,
                     point: float, buffer_pts: float) -> str:
    """A zone-entry setup is 'ready' (actionable on a market order now) when the
    latest price sits inside the point-of-interest zone; otherwise 'forming'
    (a valid structure exists but price must retrace into it first)."""
    price = series[0]["close"]
    buf = buffer_pts * point
    return "ready" if (zone_lo - buf) <= price <= (zone_hi + buf) else "forming"


# --------------------------------------------------------------------------- #
# Strategy 1: liquidity sweep -> market structure shift -> FVG (the EA model)
# --------------------------------------------------------------------------- #

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


def _detect_sweep_mss(series: list[dict], total: int, bullish: bool, point: float,
                      k: int, min_fvg_points: float, sweep_buffer_points: float,
                      entry_midpoint: bool, fallback_rr: float, digits: int):
    sweep = _find_liquidity_sweep(series, total, bullish, k)
    if sweep is None or sweep["sweep_idx"] > MAX_BARS_AFTER_SWEEP:
        return None

    out: dict = {
        "strategy": "liquidity_sweep_mss",
        "direction": "bullish" if bullish else "bearish",
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
    tp = target if target is not None else (
        entry + sl_dist * fallback_rr if bullish else entry - sl_dist * fallback_rr)
    out.update(_finalize(entry, sl, tp, digits))
    return out


# --------------------------------------------------------------------------- #
# Strategy 2: order block (last opposing candle before a break of structure)
# --------------------------------------------------------------------------- #

def _detect_order_block(series: list[dict], total: int, bullish: bool, point: float,
                        k: int, buffer_pts: float, fallback_rr: float, digits: int):
    if bullish:
        sh = _recent_swing(series, total, k, want_high=True)
        if sh is None:
            return None
        level = series[sh]["high"]
        brk = next((b for b in range(sh - 1, -1, -1) if series[b]["close"] > level), None)
        if brk is None:
            return None
        ob = next((o for o in range(brk + 1, min(sh + 2, total))
                   if series[o]["close"] < series[o]["open"]), None)
        if ob is None:
            return None
        zone_lo, zone_hi = series[ob]["low"], series[ob]["high"]
        entry = (zone_lo + zone_hi) / 2.0
        sl = zone_lo - buffer_pts * point
        target = _find_liquidity_target(series, total, True, entry, k)
        tp = target if target is not None else entry + abs(entry - sl) * fallback_rr
    else:
        slw = _recent_swing(series, total, k, want_high=False)
        if slw is None:
            return None
        level = series[slw]["low"]
        brk = next((b for b in range(slw - 1, -1, -1) if series[b]["close"] < level), None)
        if brk is None:
            return None
        ob = next((o for o in range(brk + 1, min(slw + 2, total))
                   if series[o]["close"] > series[o]["open"]), None)
        if ob is None:
            return None
        zone_lo, zone_hi = series[ob]["low"], series[ob]["high"]
        entry = (zone_lo + zone_hi) / 2.0
        sl = zone_hi + buffer_pts * point
        target = _find_liquidity_target(series, total, False, entry, k)
        tp = target if target is not None else entry - abs(entry - sl) * fallback_rr

    out = {
        "strategy": "order_block",
        "direction": "bullish" if bullish else "bearish",
        "stage": _stage_from_zone(series, zone_lo, zone_hi, point, buffer_pts),
        "zone_high": round(zone_hi, digits),
        "zone_low": round(zone_lo, digits),
    }
    out.update(_finalize(entry, sl, tp, digits))
    return out


# --------------------------------------------------------------------------- #
# Strategy 3: standalone fair value gap (unfilled 3-candle imbalance)
# --------------------------------------------------------------------------- #

def _detect_fvg(series: list[dict], total: int, bullish: bool, point: float,
                k: int, min_fvg_points: float, buffer_pts: float,
                fallback_rr: float, digits: int):
    min_size = min_fvg_points * point
    price = series[0]["close"]
    buf = buffer_pts * point
    for i in range(1, min(total - 1, FVG_SCAN_BARS)):
        older_high = series[i + 1]["high"]
        older_low = series[i + 1]["low"]
        newer_high = series[i - 1]["high"]
        newer_low = series[i - 1]["low"]
        if bullish:
            if newer_low - older_high < min_size:
                continue
            zone_lo, zone_hi = older_high, newer_low
            if price < zone_lo - buf:          # gap already filled through -> invalid
                continue
            entry = (zone_lo + zone_hi) / 2.0
            sl = zone_lo - buffer_pts * point
            target = _find_liquidity_target(series, total, True, entry, k)
            tp = target if target is not None else entry + abs(entry - sl) * fallback_rr
        else:
            if older_low - newer_high < min_size:
                continue
            zone_lo, zone_hi = newer_high, older_low
            if price > zone_hi + buf:
                continue
            entry = (zone_lo + zone_hi) / 2.0
            sl = zone_hi + buffer_pts * point
            target = _find_liquidity_target(series, total, False, entry, k)
            tp = target if target is not None else entry - abs(entry - sl) * fallback_rr

        out = {
            "strategy": "fair_value_gap",
            "direction": "bullish" if bullish else "bearish",
            "stage": _stage_from_zone(series, zone_lo, zone_hi, point, buffer_pts),
            "zone_high": round(zone_hi, digits),
            "zone_low": round(zone_lo, digits),
        }
        out.update(_finalize(entry, sl, tp, digits))
        return out
    return None


# --------------------------------------------------------------------------- #
# Strategy 4: breaker block (a failed order block, retested from the far side)
# --------------------------------------------------------------------------- #

def _detect_breaker(series: list[dict], total: int, bullish: bool, point: float,
                    k: int, buffer_pts: float, fallback_rr: float, digits: int):
    sweep = _find_liquidity_sweep(series, total, bullish, k)
    if sweep is None or sweep["sweep_idx"] > MAX_BARS_AFTER_SWEEP:
        return None
    mss = _find_mss(series, bullish, sweep["sweep_idx"], k)
    if mss is None:
        return None
    lo_i, hi_i = mss["mss_idx"] + 1, sweep["sweep_idx"]
    if lo_i > hi_i:
        return None

    if bullish:
        cand = [o for o in range(lo_i, hi_i + 1) if series[o]["close"] < series[o]["open"]]
        if not cand:
            return None
        ob = min(cand, key=lambda o: series[o]["low"])
        zone_lo, zone_hi = series[ob]["low"], series[ob]["high"]
        entry = (zone_lo + zone_hi) / 2.0
        sl = zone_lo - buffer_pts * point
        target = _find_liquidity_target(series, total, True, entry, k)
        tp = target if target is not None else entry + abs(entry - sl) * fallback_rr
    else:
        cand = [o for o in range(lo_i, hi_i + 1) if series[o]["close"] > series[o]["open"]]
        if not cand:
            return None
        ob = max(cand, key=lambda o: series[o]["high"])
        zone_lo, zone_hi = series[ob]["low"], series[ob]["high"]
        entry = (zone_lo + zone_hi) / 2.0
        sl = zone_hi + buffer_pts * point
        target = _find_liquidity_target(series, total, False, entry, k)
        tp = target if target is not None else entry - abs(entry - sl) * fallback_rr

    out = {
        "strategy": "breaker_block",
        "direction": "bullish" if bullish else "bearish",
        "stage": _stage_from_zone(series, zone_lo, zone_hi, point, buffer_pts),
        "zone_high": round(zone_hi, digits),
        "zone_low": round(zone_lo, digits),
    }
    out.update(_finalize(entry, sl, tp, digits))
    return out


# --------------------------------------------------------------------------- #
# Strategy 5: turtle soup (false break of the prior range extreme)
# --------------------------------------------------------------------------- #

def _detect_turtle_soup(series: list[dict], total: int, bullish: bool, point: float,
                        k: int, buffer_pts: float, digits: int):
    if total < TURTLE_LOOKBACK + 4:
        return None
    for i in range(0, k + 3):
        if i + 1 + TURTLE_LOOKBACK > total:
            break
        window = range(i + 1, i + 1 + TURTLE_LOOKBACK)
        win_hi = max(series[j]["high"] for j in window)
        win_lo = min(series[j]["low"] for j in window)
        c = series[i]
        if bullish and c["low"] < win_lo and c["close"] > win_lo:
            entry = c["close"]
            sl = c["low"] - buffer_pts * point
            tp = win_hi
        elif not bullish and c["high"] > win_hi and c["close"] < win_hi:
            entry = c["close"]
            sl = c["high"] + buffer_pts * point
            tp = win_lo
        else:
            continue
        out = {
            "strategy": "turtle_soup",
            "direction": "bullish" if bullish else "bearish",
            # momentum reversal: only actionable while the false break is fresh
            "stage": "ready" if i <= 2 else "forming",
            "false_break_extreme": round(c["low"] if bullish else c["high"], digits),
            "bars_since_break": i,
        }
        out.update(_finalize(entry, sl, tp, digits))
        return out
    return None


# --------------------------------------------------------------------------- #
# Strategy 6: optimal trade entry (0.62-0.79 fib of the recent impulse leg)
# --------------------------------------------------------------------------- #

def _detect_ote(series: list[dict], total: int, bullish: bool, point: float,
                k: int, buffer_pts: float, digits: int):
    sh = _recent_swing(series, total, k, want_high=True)
    slw = _recent_swing(series, total, k, want_high=False)
    if sh is None or slw is None:
        return None

    if bullish:
        if not slw > sh:          # for an up leg the low must be older than the high
            return None
        leg_low, leg_high = series[slw]["low"], series[sh]["high"]
        rng = leg_high - leg_low
        if rng <= 0:
            return None
        z_hi = leg_high - 0.62 * rng
        z_lo = leg_high - 0.79 * rng
        entry = (z_hi + z_lo) / 2.0
        sl = leg_low - buffer_pts * point
        tp = leg_high
    else:
        if not sh > slw:          # for a down leg the high must be older than the low
            return None
        leg_high, leg_low = series[sh]["high"], series[slw]["low"]
        rng = leg_high - leg_low
        if rng <= 0:
            return None
        z_lo = leg_low + 0.62 * rng
        z_hi = leg_low + 0.79 * rng
        entry = (z_hi + z_lo) / 2.0
        sl = leg_high + buffer_pts * point
        tp = leg_low

    out = {
        "strategy": "optimal_trade_entry",
        "direction": "bullish" if bullish else "bearish",
        "stage": _stage_from_zone(series, z_lo, z_hi, point, buffer_pts),
        "ote_zone_high": round(z_hi, digits),
        "ote_zone_low": round(z_lo, digits),
    }
    out.update(_finalize(entry, sl, tp, digits))
    return out


# --------------------------------------------------------------------------- #
# Context: HTF bias, nearest swings, premium/discount, equal highs/lows
# --------------------------------------------------------------------------- #

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
    pools price is drawing toward, regardless of any setup."""
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


def _equal_levels(series: list[dict], total: int, k: int, point: float,
                  digits: int, tol_pts: float = 10.0) -> dict:
    """Equal highs / equal lows — clustered swing points that mark resting
    liquidity (a strong draw-on-liquidity target)."""
    tol = tol_pts * point if point > 0 else 0.0
    highs, lows = [], []
    for i in range(k, total - k):
        if _is_swing_high(series, i, k):
            highs.append(series[i]["high"])
        if _is_swing_low(series, i, k):
            lows.append(series[i]["low"])
        if len(highs) >= 5 and len(lows) >= 5:
            break

    def cluster(levels: list[float]):
        for a in range(len(levels)):
            for b in range(a + 1, len(levels)):
                if abs(levels[a] - levels[b]) <= tol:
                    return round((levels[a] + levels[b]) / 2.0, digits)
        return None

    return {"equal_highs": cluster(highs), "equal_lows": cluster(lows)}


def _premium_discount(candles: list[dict], digits: int) -> dict:
    """Where current price sits in the recent dealing range — a core ICT
    concept (sell in premium, buy in discount)."""
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


# --------------------------------------------------------------------------- #
# Top-level assembler
# --------------------------------------------------------------------------- #

def _detect_all(series: list[dict], total: int, bullish: bool, point: float, k: int,
                min_fvg_points: float, sweep_buffer_points: float, entry_midpoint: bool,
                fallback_rr: float, digits: int) -> list[dict]:
    detectors = [
        _detect_sweep_mss(series, total, bullish, point, k, min_fvg_points,
                          sweep_buffer_points, entry_midpoint, fallback_rr, digits),
        _detect_order_block(series, total, bullish, point, k, sweep_buffer_points,
                            fallback_rr, digits),
        _detect_fvg(series, total, bullish, point, k, min_fvg_points,
                    sweep_buffer_points, fallback_rr, digits),
        _detect_breaker(series, total, bullish, point, k, sweep_buffer_points,
                        fallback_rr, digits),
        _detect_turtle_soup(series, total, bullish, point, k, sweep_buffer_points, digits),
        _detect_ote(series, total, bullish, point, k, sweep_buffer_points, digits),
    ]
    return [d for d in detectors if d is not None]


def compute_ict_features(candles: list[dict], htf_candles: list[dict] | None,
                         point: float, *, swing_lr: int = 3,
                         min_fvg_points: float = 30.0, sweep_buffer_points: float = 20.0,
                         entry_midpoint: bool = True, fallback_rr: float = 2.0,
                         require_htf_bias: bool = True) -> dict:
    """Top-level: returns HTF bias, dealing-range context, and a list of all
    detected setups across every strategy (both directions), each tagged with
    its strategy name and a 'ready'/'forming' (or sweep/MSS progression) stage."""
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
    setups: list[dict] = []
    if bull_bias:
        setups += _detect_all(series, total, True, point, k, min_fvg_points,
                              sweep_buffer_points, entry_midpoint, fallback_rr, digits)
    if bear_bias:
        setups += _detect_all(series, total, False, point, k, min_fvg_points,
                              sweep_buffer_points, entry_midpoint, fallback_rr, digits)
    # surface actionable ("ready") setups first
    setups.sort(key=lambda s: 0 if s.get("stage") == "ready" else 1)

    return {
        "available": True,
        "htf_bias": bias_label,
        "strategies_evaluated": list(STRATEGIES),
        "context": {**_nearest_swings(series, total, k, digits),
                    **_premium_discount(candles, digits),
                    **_equal_levels(series, total, k, point, digits)},
        "setups": setups,
    }
