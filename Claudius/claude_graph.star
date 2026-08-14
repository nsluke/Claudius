load("render.star", "render")

# 64x32 vertical bar chart. Colors mirror UsageBucket.swift.
BG_COLOR = "#222"
SESSION_COLOR = "#4caf50"
WEEKLY_COLOR = "#d97757"
SCOPED_COLOR = "#7c6bd9"
ALERT_COLOR = "#ff0000"

def alerted(fraction, base_color):
    return base_color if fraction < 0.9 else ALERT_COLOR

def main(config):
    session_pct_raw = config.get("session_pct", "")
    weekly_raw = config.get("weekly_pct", "")
    scoped_raw = config.get("scoped1_pct", "")

    # Web mode if ANY window was reported. Keying this off session_pct alone
    # discarded a weekly or model-scoped cap whenever the session window was
    # missing, and fell through to rendering empty local-mode bars.
    is_web = session_pct_raw != "" or weekly_raw != "" or scoped_raw != ""

    # Bars are collected rather than hardcoded in pairs, so an absent bucket is
    # omitted entirely. That matters here: the `max(..., 1)` floor below would
    # otherwise paint a 1px stub for a bucket that doesn't exist.
    bars = []

    if is_web:
        if session_pct_raw != "":
            session_pct = int(session_pct_raw)
            s_pct = min(session_pct / 100.0, 1.0) if session_pct > 0 else 0.0
            bars.append({
                "pct": s_pct,
                "color": alerted(s_pct, SESSION_COLOR),
                "label": str(session_pct) + "%",
            })

        if weekly_raw != "":
            weekly_pct = int(weekly_raw)
            w_pct = min(weekly_pct / 100.0, 1.0) if weekly_pct > 0 else 0.0
            bars.append({
                "pct": w_pct,
                "color": alerted(w_pct, WEEKLY_COLOR),
                "label": str(weekly_pct) + "%",
            })

        if scoped_raw != "":
            scoped_pct = int(scoped_raw)
            c_pct = min(scoped_pct / 100.0, 1.0) if scoped_pct > 0 else 0.0
            bars.append({
                "pct": c_pct,
                "color": alerted(c_pct, SCOPED_COLOR),
                "label": str(scoped_pct) + "%",
            })
    else:
        usage_str   = config.get("usage", "")
        tokens_val  = int(config.get("tokens", "0"))
        cost_limit  = float(config.get("cost_limit",  "15.00"))
        token_limit = float(config.get("token_limit", "5000000"))
        usage_val   = float(usage_str) if usage_str else 0.0

        s_pct = min(usage_val  / cost_limit,  1.0) if cost_limit  > 0 else 0.0
        w_pct = min(tokens_val / token_limit, 1.0) if token_limit > 0 else 0.0

        bars.append({
            "pct": s_pct,
            "color": alerted(s_pct, WEEKLY_COLOR),
            "label": "$" + (usage_str if usage_str else "0"),
        })
        bars.append({
            "pct": w_pct,
            "color": alerted(w_pct, SESSION_COLOR),
            "label": (str(int(tokens_val / 1000)) + "k") if tokens_val >= 1000 else str(tokens_val),
        })

    bar_max = 22
    # Three bars plus space_evenly gutters have to fit 64px.
    bar_w = 18 if len(bars) >= 3 else 24

    def vbar(bar):
        filled_h = max(int(bar_max * bar["pct"]), 1)
        return render.Stack(
            children = [
                render.Box(width = bar_w, height = bar_max, color = BG_COLOR),
                render.Padding(
                    pad   = (0, bar_max - filled_h, 0, 0),
                    child = render.Box(width = bar_w, height = filled_h, color = bar["color"]),
                ),
            ],
        )

    return render.Root(
        child = render.Column(
            expanded = True,
            main_align = "space_between",
            children = [
                render.Row(
                    expanded   = True,
                    main_align = "space_evenly",
                    children = [
                        render.Text(bar["label"], font = "tom-thumb", color = bar["color"])
                        for bar in bars
                    ],
                ),
                render.Row(
                    expanded   = True,
                    main_align = "space_evenly",
                    children = [vbar(bar) for bar in bars],
                ),
            ],
        ),
    )
