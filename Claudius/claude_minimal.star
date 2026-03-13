load("render.star", "render")

def main(config):
    usage_str = config.get("usage", "0.00")
    tokens_val = int(config.get("tokens", "0"))
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
