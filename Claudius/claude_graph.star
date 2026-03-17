load("render.star", "render")

def main(config):
    session_pct = int(config.get("session_pct", "0"))
    weekly_pct = int(config.get("weekly_pct", "0"))
    usage_str = config.get("usage", "")
    tokens_val = int(config.get("tokens", "0"))

    if session_pct > 0 or weekly_pct > 0 or config.get("session_pct", "") != "":
        # Web mode: show percentages with visual bars
        s_pct = session_pct / 100.0 if session_pct <= 100 else 1.0
        w_pct = weekly_pct / 100.0 if weekly_pct <= 100 else 1.0
        session_color = "#4caf50" if s_pct < 0.9 else "#ff0000"
        weekly_color = "#d97757" if w_pct < 0.9 else "#ff0000"

        # Vertical bars representing session and weekly usage
        max_height = 20
        session_h = int(max_height * s_pct) if int(max_height * s_pct) > 0 else 1
        weekly_h = int(max_height * w_pct) if int(max_height * w_pct) > 0 else 1

        return render.Root(
            child = render.Column(
                main_align = "space_evenly",
                cross_align = "center",
                children = [
                    render.Row(
                        children = [
                            render.Text(str(session_pct) + "%", font="tb-8", color=session_color),
                            render.Box(width=4, height=1),
                            render.Text(str(weekly_pct) + "%", font="tb-8", color=weekly_color),
                        ]
                    ),
                    render.Row(
                        main_align = "center",
                        cross_align = "end",
                        children = [
                            render.Box(width=16, height=session_h, color=session_color),
                            render.Box(width=4, height=1),
                            render.Box(width=16, height=weekly_h, color=weekly_color),
                        ]
                    ),
                    render.Row(
                        children = [
                            render.Text("sess", font="CG-pixel-3x5-mono", color="#888"),
                            render.Box(width=4, height=1),
                            render.Text("week", font="CG-pixel-3x5-mono", color="#888"),
                        ]
                    ),
                ]
            )
        )
    else:
        # Local mode
        tokens_str = str(int(tokens_val / 1000)) + "k" if tokens_val >= 1000 else str(tokens_val)

        bars = [
            render.Box(width=2, height=4, color="#4caf50"),
            render.Box(width=2, height=8, color="#4caf50"),
            render.Box(width=2, height=6, color="#4caf50"),
            render.Box(width=2, height=12, color="#4caf50"),
            render.Box(width=2, height=10, color="#4caf50"),
        ]

        return render.Root(
            child = render.Column(
                main_align = "space_evenly",
                cross_align = "center",
                children = [
                    render.Row(
                        children = [
                            render.Text("$" + usage_str, font="tb-8", color="#d97757"),
                            render.Box(width=4, height=1),
                            render.Text(tokens_str, font="tb-8", color="#4caf50"),
                        ]
                    ),
                    render.Row(
                        main_align = "center",
                        cross_align = "end",
                        children = bars
                    )
                ]
            )
        )
