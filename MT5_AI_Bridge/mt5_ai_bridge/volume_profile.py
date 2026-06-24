"""Tick-volume profile over the visible candle window.

MT5 does not expose real traded volume for most forex/CFD symbols, only tick
volume (number of price updates) -- a proxy for activity, not true participation.
It still tends to track where real activity clustered on liquid symbols, so this
is exposed as a soft confluence signal for the AI to weigh alongside ICT
structure, never as a standalone trade trigger.
"""

from __future__ import annotations


def compute_volume_profile(candles: list[dict], num_bins: int = 20) -> dict | None:
    if len(candles) < 5:
        return None

    lo = min(c["low"] for c in candles)
    hi = max(c["high"] for c in candles)
    if hi <= lo:
        return None
    bin_size = (hi - lo) / num_bins
    bins = [0.0] * num_bins

    for c in candles:
        c_lo, c_hi, vol = c["low"], c["high"], c["volume"]
        first = max(0, min(num_bins - 1, int((c_lo - lo) / bin_size)))
        last = max(0, min(num_bins - 1, int((c_hi - lo) / bin_size)))
        span = last - first + 1
        for b in range(first, last + 1):
            bins[b] += vol / span

    total = sum(bins)
    if total <= 0:
        return None

    poc_bin = max(range(num_bins), key=lambda b: bins[b])

    # value area: expand outward from the POC bin, adding whichever neighbor
    # has more volume, until 70% of total volume is covered.
    included = {poc_bin}
    covered = bins[poc_bin]
    left, right = poc_bin - 1, poc_bin + 1
    while covered < total * 0.7 and (left >= 0 or right < num_bins):
        left_vol = bins[left] if left >= 0 else -1
        right_vol = bins[right] if right < num_bins else -1
        if left_vol >= right_vol:
            included.add(left)
            covered += bins[left]
            left -= 1
        else:
            included.add(right)
            covered += bins[right]
            right += 1

    def bin_price(b: int) -> float:
        return lo + (b + 0.5) * bin_size

    mean_vol = total / num_bins
    hvn_zones, lvn_zones = [], []
    for b in range(num_bins):
        zone = [round(lo + b * bin_size, 5), round(lo + (b + 1) * bin_size, 5)]
        if bins[b] >= mean_vol * 1.5:
            hvn_zones.append(zone)
        elif bins[b] <= mean_vol * 0.5:
            lvn_zones.append(zone)

    return {
        "poc": round(bin_price(poc_bin), 5),
        "value_area_high": round(lo + (max(included) + 1) * bin_size, 5),
        "value_area_low": round(lo + min(included) * bin_size, 5),
        "hvn_zones": hvn_zones,
        "lvn_zones": lvn_zones,
        "note": "tick-volume based (MT5 has no true traded volume for this symbol type) -- "
                "treat as a soft confluence signal, not a standalone trigger",
    }
