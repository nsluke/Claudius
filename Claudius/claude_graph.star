load("render.star", "render")

def main(config):
    usage_str = config.get("usage", "0.00")
    tokens_val = int(config.get("tokens", "0"))
    tokens_str = str(int(tokens_val / 1000)) + "k" if tokens_val >= 1000 else str(tokens_val)

    # Use some fake data for the bar chart demo
    # In a real version, we'd pass the time series data via config
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
