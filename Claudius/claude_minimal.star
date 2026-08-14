load("render.star", "render")

# 64x32. Tightest of the three layouts — 8 + 13 + 8 = 29 of 32 rows are already
# spoken for, so a third value costs the title line.
SESSION_COLOR = "#4caf50"
WEEKLY_COLOR = "#d97757"
SCOPED_COLOR = "#7c6bd9"

def main(config):
    # An absent key is the only "no value" signal pixlet can give us.
    session_raw = config.get("session_pct", "")
    weekly_raw = config.get("weekly_pct", "")
    scoped_raw = config.get("scoped1_pct", "")

    session_pct = int(session_raw) if session_raw else 0
    weekly_pct = int(weekly_raw) if weekly_raw else 0

    usage_str = config.get("usage", "")
    tokens_val = int(config.get("tokens", "0"))

    if session_pct > 0 or weekly_pct > 0 or session_raw != "":
        # Web mode
        has_weekly = weekly_raw != ""
        has_scoped = scoped_raw != ""

        children = [render.Text("Claude Usage", font = "tb-8", color = WEEKLY_COLOR)]

        # "% session" at 6x13 is ~63px on a 64px display and clipped its own
        # last glyph. "sess" keeps the hero font without running off the edge.
        children.append(
            render.Text(str(session_pct) + "% sess", font = "6x13", color = SESSION_COLOR)
        )

        if has_scoped:
            # Both weekly figures share one row, in the narrow font so
            # "70%wk 12%Fable" (~52px) stays inside the display.
            row = []
            if has_weekly:
                row.append(
                    render.Text(str(weekly_pct) + "%wk", font = "CG-pixel-3x5-mono", color = WEEKLY_COLOR)
                )
                row.append(render.Box(width = 3, height = 1))
            row.append(
                render.Text(
                    str(int(scoped_raw)) + "%" + config.get("scoped1_label", "Cap"),
                    font = "CG-pixel-3x5-mono",
                    color = SCOPED_COLOR,
                )
            )
            children.append(render.Row(main_align = "center", children = row))
        elif has_weekly:
            # Previously this rendered a literal "0% weekly" when the server
            # reported no weekly window at all.
            children.append(
                render.Text(str(weekly_pct) + "% weekly", font = "tb-8", color = WEEKLY_COLOR)
            )

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
                # Without this the column shrink-wraps to its widest child and
                # cross_align has nothing to center against, pinning everything
                # to the left edge.
                expanded = True,
                children = [
                    render.Text("Claude Usage", font="tb-8", color="#d97757"),
                    render.Text("$" + usage_str, font="6x13", color="#fff"),
                    render.Text(tokens_str + " tokens", font="tb-8", color="#4caf50"),
                ]
            )
        )
