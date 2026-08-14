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

def bar_group(label, pct, color, label_font, bar_height):
    """A label+percentage row above its progress bar."""
    fill = int(MAX_BAR * (min(pct, 100) / 100.0))
    return [
        render.Row(
            main_align = "space_between",
            expanded = True,
            children = [
                render.Text(label, font = label_font, color = color),
                render.Text(str(pct) + "%", font = "CG-pixel-3x5-mono", color = "#fff"),
            ],
        ),
        render.Stack(
            children = [
                render.Box(width = MAX_BAR, height = bar_height, color = BG_COLOR),
                render.Box(width = fill, height = bar_height, color = color),
            ],
        ),
    ]

def main(config):
    # Pixlet stringifies every arg, so an ABSENT key is the only "no value"
    # signal — always test the raw string before converting.
    session_raw = config.get("session_pct", "")
    weekly_raw = config.get("weekly_pct", "")
    scoped_raw = config.get("scoped1_pct", "")

    session_pct = int(session_raw) if session_raw else 0
    weekly_pct = int(weekly_raw) if weekly_raw else 0

    # Local mode: raw cost/token values
    usage_str = config.get("usage", "")
    tokens_val = int(config.get("tokens", "0"))

    max_bar_width = MAX_BAR
    bg_color = BG_COLOR

    # Web-mode gate. Deliberately NOT widened to include scoped1_pct: session_pct
    # is always emitted in web mode, so keying off it avoids a lone scoped value
    # flipping the layout and painting a bogus 0% session bar.
    if session_pct > 0 or weekly_pct > 0 or session_raw != "":
        # --- WEB MODE: session %, weekly %, and any model-scoped cap ---
        has_weekly = weekly_raw != ""
        has_scoped = scoped_raw != ""

        group_count = 1 + (1 if has_weekly else 0) + (1 if has_scoped else 0)

        # Three groups only fit if the labels and bars shrink: 3 x (5 + 3) = 24
        # of the 32 available rows. Two groups keep the original proportions.
        compact = group_count >= 3
        label_font = "CG-pixel-3x5-mono" if compact else "tb-8"
        bar_height = 3 if compact else 4

        children = bar_group(
            "Sess" if compact else "Session",
            session_pct,
            alerted(session_pct, SESSION_COLOR),
            label_font,
            bar_height,
        )

        if has_weekly:
            if not compact:
                children = children + [render.Box(width = 64, height = 2)]
            children = children + bar_group(
                "Week",
                weekly_pct,
                alerted(weekly_pct, WEEKLY_COLOR),
                label_font,
                bar_height,
            )

        if has_scoped:
            scoped_pct = int(scoped_raw)
            children = children + bar_group(
                config.get("scoped1_label", "Cap"),
                scoped_pct,
                alerted(scoped_pct, SCOPED_COLOR),
                label_font,
                bar_height,
            )

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
                    render.Stack(
                        children = [
                            render.Box(width=max_bar_width, height=4, color=bg_color),
                            render.Box(width=cost_bar_width, height=4, color=cost_color),
                        ]
                    ),
                    render.Box(width=64, height=2),
                    render.Row(
                        main_align = "space_between",
                        expanded = True,
                        children = [
                            render.Text("Tkns", font="tb-8", color=token_color),
                            render.Text(tokens_str + "/" + token_limit_str, font="CG-pixel-3x5-mono", color="#fff"),
                        ]
                    ),
                    render.Stack(
                        children = [
                            render.Box(width=max_bar_width, height=4, color=bg_color),
                            render.Box(width=token_bar_width, height=4, color=token_color),
                        ]
                    ),
                ]
            )
        )
