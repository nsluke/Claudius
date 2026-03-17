load("render.star", "render")

def main(config):
    # Web mode: utilization percentages from claude.ai
    session_pct = int(config.get("session_pct", "0"))
    weekly_pct = int(config.get("weekly_pct", "0"))

    # Local mode: raw cost/token values
    usage_str = config.get("usage", "")
    tokens_val = int(config.get("tokens", "0"))

    max_bar_width = 64
    bg_color = "#222"

    # Determine if we're in web mode (session_pct passed) or local mode
    if session_pct > 0 or weekly_pct > 0 or config.get("session_pct", "") != "":
        # --- WEB MODE: Show session % and weekly % ---
        s_pct = session_pct / 100.0 if session_pct <= 100 else 1.0
        w_pct = weekly_pct / 100.0 if weekly_pct <= 100 else 1.0

        session_bar = int(max_bar_width * s_pct)
        weekly_bar = int(max_bar_width * w_pct)

        session_color = "#4caf50" if s_pct < 0.9 else "#ff0000"
        weekly_color = "#d97757" if w_pct < 0.9 else "#ff0000"

        return render.Root(
            child = render.Column(
                main_align = "space_evenly",
                cross_align = "start",
                children = [
                    render.Row(
                        main_align = "space_between",
                        expanded = True,
                        children = [
                            render.Text("Sess", font="tb-8", color=session_color),
                            render.Text(str(session_pct) + "%", font="CG-pixel-3x5-mono", color="#fff"),
                        ]
                    ),
                    render.Stack(
                        children = [
                            render.Box(width=max_bar_width, height=4, color=bg_color),
                            render.Box(width=session_bar, height=4, color=session_color),
                        ]
                    ),
                    render.Box(width=64, height=2),
                    render.Row(
                        main_align = "space_between",
                        expanded = True,
                        children = [
                            render.Text("Week", font="tb-8", color=weekly_color),
                            render.Text(str(weekly_pct) + "%", font="CG-pixel-3x5-mono", color="#fff"),
                        ]
                    ),
                    render.Stack(
                        children = [
                            render.Box(width=max_bar_width, height=4, color=bg_color),
                            render.Box(width=weekly_bar, height=4, color=weekly_color),
                        ]
                    ),
                ]
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
