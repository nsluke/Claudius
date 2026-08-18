load("render.star", "render")

# 64x32 display. Colors mirror UsageBucket.swift — keep them in sync by hand.
MAX_BAR = 64
BG_COLOR = "#222"
SESSION_COLOR = "#4caf50"
WEEKLY_COLOR = "#d97757"
SCOPED_COLOR = "#7c6bd9"
ALERT_COLOR = "#ff0000"

def alerted(pct, base_color):
    return base_color if pct < 90 else ALERT_COLOR

def stacked_bar(fill, height, color):
    """A progress bar. `fill` is in pixels, 0..MAX_BAR."""
    # pixlet treats Box(width = 0) as "unset" and expands the box to fill its
    # parent, so a 0% bar would paint solid full-width — indistinguishable from
    # 100%. Omit the fill box entirely instead of passing a zero width.
    children = [render.Box(width = MAX_BAR, height = height, color = BG_COLOR)]
    if fill > 0:
        children.append(render.Box(width = fill, height = height, color = color))
    return render.Stack(children = children)

def bar_group(label, pct, color, label_font, bar_height):
    """A label+percentage row above its progress bar."""
    return [
        render.Row(
            main_align = "space_between",
            expanded = True,
            children = [
                render.Text(label, font = label_font, color = color),
                render.Text(str(pct) + "%", font = "CG-pixel-3x5-mono", color = "#fff"),
            ],
        ),
        stacked_bar(int(MAX_BAR * (min(pct, 100) / 100.0)), bar_height, color),
    ]

def main(config):
    # Pixlet stringifies every arg, so an ABSENT key is the only "no value"
    # signal — always test the raw string before converting.
    session_raw = config.get("session_pct", "")
    weekly_raw = config.get("weekly_pct", "")
    scoped_raw = config.get("scoped1_pct", "")

    has_session = session_raw != ""
    has_weekly = weekly_raw != ""
    has_scoped = scoped_raw != ""

    # Local mode: raw cost/token values
    usage_str = config.get("usage", "")
    tokens_val = int(config.get("tokens", "0"))

    max_bar_width = MAX_BAR
    bg_color = BG_COLOR

    # Web mode if ANY usage window was reported. Keying this off session_pct
    # alone meant an account reporting only a weekly or model-scoped cap fell
    # through to local mode and rendered cost/token garbage.
    if has_session or has_weekly or has_scoped:
        # --- WEB MODE: one group per reported window ---
        groups = []
        if has_session:
            groups.append(("Session", "Sess", int(session_raw), SESSION_COLOR))
        if has_weekly:
            groups.append(("Week", "Week", int(weekly_raw), WEEKLY_COLOR))
        if has_scoped:
            scoped_label = config.get("scoped1_label", "Cap")
            groups.append((scoped_label, scoped_label, int(scoped_raw), SCOPED_COLOR))

        # Three groups only fit if the labels and bars shrink: 3 x (5 + 3) = 24
        # of the 32 available rows. Fewer groups keep the original proportions.
        compact = len(groups) >= 3
        label_font = "CG-pixel-3x5-mono" if compact else "tb-8"
        bar_height = 3 if compact else 4

        children = []
        for i, group in enumerate(groups):
            if i > 0 and not compact:
                children.append(render.Box(width = 64, height = 2))
            label = group[1] if compact else group[0]
            pct = group[2]
            children = children + bar_group(label, pct, alerted(pct, group[3]), label_font, bar_height)

        return render.Root(
            child = render.Column(
                main_align = "space_evenly",
                cross_align = "start",
                # Expanding only in compact mode lets space_evenly spread the
                # three groups over the full 32 rows (they occupy 24), while
                # leaving the two-group layout pixel-identical to before.
                expanded = compact,
                children = children,
            )
        )
    else:
        # --- LOCAL MODE: Show cost and tokens ---
        usage_val = float(usage_str) if usage_str else 0.0
        tokens_str = str(int(tokens_val / 1000)) + "k" if tokens_val >= 1000 else str(tokens_val)

        cost_limit  = float(config.get("cost_limit",  "15.00"))
        token_limit = float(config.get("token_limit", "5000000"))

        cost_limit_str = str(int(cost_limit)) if cost_limit == int(cost_limit) else str(cost_limit)
        token_limit_str = str(int(token_limit / 1000)) + "k" if token_limit >= 1000 else str(int(token_limit))

        cost_pct = usage_val / cost_limit if cost_limit > 0 else 0.0
        if cost_pct > 1.0: cost_pct = 1.0

        token_pct = tokens_val / token_limit if token_limit > 0 else 0.0
        if token_pct > 1.0: token_pct = 1.0

        cost_bar_width = int(max_bar_width * cost_pct)
        token_bar_width = int(max_bar_width * token_pct)

        cost_color = "#d97757" if cost_pct < 0.9 else "#ff0000"
        token_color = "#4caf50" if token_pct < 0.9 else "#ff0000"

        return render.Root(
            child = render.Column(
                main_align = "space_evenly",
                cross_align = "start",
                children = [
                    render.Row(
                        main_align = "space_between",
                        expanded = True,
                        children = [
                            render.Text("Cost", font="tb-8", color=cost_color),
                            render.Text("$" + usage_str + "/$" + cost_limit_str, font="CG-pixel-3x5-mono", color="#fff"),
                        ]
                    ),
                    stacked_bar(cost_bar_width, 4, cost_color),
                    render.Box(width=64, height=2),
                    render.Row(
                        main_align = "space_between",
                        expanded = True,
                        children = [
                            render.Text("Tkns", font="tb-8", color=token_color),
                            render.Text(tokens_str + "/" + token_limit_str, font="CG-pixel-3x5-mono", color="#fff"),
                        ]
                    ),
                    stacked_bar(token_bar_width, 4, token_color),
                ]
            )
        )
