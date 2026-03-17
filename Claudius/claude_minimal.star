load("render.star", "render")

def main(config):
    session_pct = int(config.get("session_pct", "0"))
    weekly_pct = int(config.get("weekly_pct", "0"))
    usage_str = config.get("usage", "")
    tokens_val = int(config.get("tokens", "0"))

    if session_pct > 0 or weekly_pct > 0 or config.get("session_pct", "") != "":
        # Web mode
        return render.Root(
            child = render.Column(
                main_align = "space_evenly",
                cross_align = "center",
                children = [
                    render.Text("Claude Usage", font="tb-8", color="#d97757"),
                    render.Text(str(session_pct) + "% session", font="6x13", color="#4caf50"),
                    render.Text(str(weekly_pct) + "% weekly", font="tb-8", color="#d97757"),
                ]
            )
        )
    else:
        # Local mode
        tokens_str = str(int(tokens_val / 1000)) + "k" if tokens_val >= 1000 else str(tokens_val)
        return render.Root(
            child = render.Column(
                main_align = "space_evenly",
                cross_align = "center",
                children = [
                    render.Text("Claude Usage", font="tb-8", color="#d97757"),
                    render.Text("$" + usage_str, font="6x13", color="#fff"),
                    render.Text(tokens_str + " tokens", font="tb-8", color="#4caf50"),
                ]
            )
        )
