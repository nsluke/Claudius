load("render.star", "render")

# 64x32. Tightest of the three layouts — the hero line alone is 13 rows.
SESSION_COLOR = "#4caf50"
WEEKLY_COLOR = "#d97757"
SCOPED_COLOR = "#7c6bd9"

def main(config):
    # An absent key is the only "no value" signal pixlet can give us.
    session_raw = config.get("session_pct", "")
    weekly_raw = config.get("weekly_pct", "")
    scoped_raw = config.get("scoped1_pct", "")

    has_session = session_raw != ""
    has_weekly = weekly_raw != ""
    has_scoped = scoped_raw != ""

    usage_str = config.get("usage", "")
    tokens_val = int(config.get("tokens", "0"))

    # Web mode if ANY window was reported — not just the session one.
    if has_session or has_weekly or has_scoped:
        scoped_label = config.get("scoped1_label", "Cap")

        # Whichever windows aren't the hero share the bottom line. Each carries
        # a long form (used when it's alone) and a short one (when two share).
        secondary = []

        # The hero is the session window when we have it. When we don't, promote
        # the next window rather than printing a fabricated "0% sess" for a
        # window the server never reported.
        if has_session:
            hero_text = str(int(session_raw)) + "% sess"
            hero_color = SESSION_COLOR
            if has_weekly:
                secondary.append((str(int(weekly_raw)) + "%wk", str(int(weekly_raw)) + "% weekly", WEEKLY_COLOR))
        elif has_weekly:
            hero_text = str(int(weekly_raw)) + "% week"
            hero_color = WEEKLY_COLOR
        else:
            hero_text = str(int(scoped_raw)) + "% " + scoped_label
            hero_color = SCOPED_COLOR

        if has_scoped and (has_session or has_weekly):
            secondary.append((
                str(int(scoped_raw)) + "%" + scoped_label,
                str(int(scoped_raw)) + "% " + scoped_label,
                SCOPED_COLOR,
            ))

        children = [
            render.Text("Claude Usage", font = "tb-8", color = WEEKLY_COLOR),
            # "% session" at 6x13 is ~63px on a 64px display and clipped its own
            # last glyph. "sess" keeps the hero font without running off the edge.
            render.Text(hero_text, font = "6x13", color = hero_color),
        ]

        if len(secondary) == 1:
            children.append(render.Text(secondary[0][1], font = "tb-8", color = secondary[0][2]))
        elif len(secondary) > 1:
            # Two values share the line, in the narrow font so
            # "70%wk 12%Fable" (~52px) stays inside the display.
            row = []
            for i, item in enumerate(secondary):
                if i > 0:
                    row.append(render.Box(width = 3, height = 1))
                row.append(render.Text(item[0], font = "CG-pixel-3x5-mono", color = item[2]))
            children.append(render.Row(main_align = "center", children = row))

        return render.Root(
            child = render.Column(
                main_align = "space_evenly",
                cross_align = "center",
                # Without this the column shrink-wraps to its widest child and
                # cross_align has nothing to center against, pinning everything
                # to the left edge.
                expanded = True,
                children = children,
            )
        )
    else:
        # Local mode
        tokens_str = str(int(tokens_val / 1000)) + "k" if tokens_val >= 1000 else str(tokens_val)
        return render.Root(
            child = render.Column(
                main_align = "space_evenly",
                cross_align = "center",
                expanded = True,
                children = [
                    render.Text("Claude Usage", font="tb-8", color="#d97757"),
                    render.Text("$" + usage_str, font="6x13", color="#fff"),
                    render.Text(tokens_str + " tokens", font="tb-8", color="#4caf50"),
                ]
            )
        )
