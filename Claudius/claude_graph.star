load("render.star", "render")

def main(config):
    session_pct_raw = config.get("session_pct", "")
    is_web = session_pct_raw != ""

    if is_web:
        session_pct = int(session_pct_raw)
        weekly_pct  = int(config.get("weekly_pct", "0"))
        s_pct = min(session_pct / 100.0, 1.0) if session_pct > 0 else 0.0
        w_pct = min(weekly_pct  / 100.0, 1.0) if weekly_pct  > 0 else 0.0
        s_color = "#4caf50" if s_pct < 0.9 else "#ff0000"
        w_color = "#d97757" if w_pct < 0.9 else "#ff0000"
        s_label = str(session_pct) + "%"
        w_label = str(weekly_pct)  + "%"
    else:
        usage_str   = config.get("usage", "")
        tokens_val  = int(config.get("tokens", "0"))
        cost_limit  = float(config.get("cost_limit",  "15.00"))
        token_limit = float(config.get("token_limit", "5000000"))
        usage_val   = float(usage_str) if usage_str else 0.0
        s_pct = min(usage_val  / cost_limit,  1.0) if cost_limit  > 0 else 0.0
        w_pct = min(tokens_val / token_limit, 1.0) if token_limit > 0 else 0.0
        s_color = "#d97757" if s_pct < 0.9 else "#ff0000"
        w_color = "#4caf50" if w_pct < 0.9 else "#ff0000"
        s_label = "$" + (usage_str if usage_str else "0")
        w_label = (str(int(tokens_val / 1000)) + "k") if tokens_val >= 1000 else str(tokens_val)

    bar_max  = 22
    bar_w    = 24
    bg_color = "#222"
    s_h = max(int(bar_max * s_pct), 1)
    w_h = max(int(bar_max * w_pct), 1)

    def vbar(filled_h, color):
        return render.Stack(
            children = [
                render.Box(width = bar_w, height = bar_max, color = bg_color),
                render.Padding(
                    pad   = (0, bar_max - filled_h, 0, 0),
                    child = render.Box(width = bar_w, height = filled_h, color = color),
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
                        render.Text(s_label, font = "tom-thumb", color = s_color),
                        render.Text(w_label, font = "tom-thumb", color = w_color),
                    ],
                ),
                render.Row(
                    expanded   = True,
                    main_align = "space_evenly",
                    children = [
                        vbar(s_h, s_color),
                        vbar(w_h, w_color),
                    ],
                ),
            ],
        ),
    )
