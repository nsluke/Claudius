load("render.star", "render")

def main(config):
    # usage arrives pre-formatted (e.g. "12.79"); tokens arrives as a raw integer string
    usage_str = config.get("usage", "0.00")
    usage_val = float(usage_str)
    tokens_val = int(config.get("tokens", "0"))
    tokens_str = str(int(tokens_val / 1000)) + "k" if tokens_val >= 1000 else str(tokens_val)
    
    # Retrieve limits (you can pass these from Swift, or hardcode them here)
    cost_limit = float(config.get("cost_limit", "7.10"))
    token_limit = float(config.get("token_limit", "41653"))

    # Calculate percentages (clamp to 1.0 to prevent the box from expanding off-screen)
    cost_pct = usage_val / cost_limit if cost_limit > 0 else 0.0
    if cost_pct > 1.0: cost_pct = 1.0
    
    token_pct = tokens_val / token_limit if token_limit > 0 else 0.0
    if token_pct > 1.0: token_pct = 1.0

    # Max width for our progress bars is the full 64 pixels of the Tidbyt screen
    max_bar_width = 64
    
    # Calculate pixel widths based on the percentage
    cost_bar_width = int(max_bar_width * cost_pct)
    token_bar_width = int(max_bar_width * token_pct)

    # Colors (Mimicking the CLI, turns red if over 90%)
    bg_color = "#222" # Dark gray for the empty background bar
    cost_color = "#d97757" if cost_pct < 0.9 else "#ff0000" 
    token_color = "#4caf50" if token_pct < 0.9 else "#ff0000" 

    return render.Root(
        child = render.Column(
            main_align = "space_evenly",
            cross_align = "start",
            children = [
                # --- COST SECTION ---
                render.Row(
                    main_align = "space_between",
                    expanded = True, # Pushes Cost to the left and $ value to the right
                    children = [
                        render.Text("Cost", font="tb-8", color=cost_color),
                        render.Text("$" + usage_str, font="CG-pixel-3x5-mono", color="#fff"),
                    ]
                ),
                # The Graphical Progress Bar
                render.Stack(
                    children = [
                        render.Box(width=max_bar_width, height=4, color=bg_color),
                        render.Box(width=cost_bar_width, height=4, color=cost_color),
                    ]
                ),
                
                # 2-pixel vertical spacer between the bars
                render.Box(width=64, height=2),

                # --- TOKEN SECTION ---
                render.Row(
                    main_align = "space_between",
                    expanded = True,
                    children = [
                        render.Text("Tkns", font="tb-8", color=token_color),
                        # Abbreviate large token numbers so they fit on screen (e.g. 19k)
                        render.Text(tokens_str, font="CG-pixel-3x5-mono", color="#fff"),
                    ]
                ),
                # The Graphical Progress Bar
                render.Stack(
                    children = [
                        render.Box(width=max_bar_width, height=4, color=bg_color),
                        render.Box(width=token_bar_width, height=4, color=token_color),
                    ]
                ),
            ]
        )
    )
