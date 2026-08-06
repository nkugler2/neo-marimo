import marimo

__generated_with = "0.19.4"
app = marimo.App()


@app.cell
def _():
    import pandas as pd
    return (pd,)


@app.cell
def _(pd):
    df = pd.DataFrame({"a": range(300), "b": [i * i for i in range(300)]})
    df
    return (df,)


@app.cell
def _():
    # Non-interactive backend: this scenario is recorded/replayed headless,
    # never with a display, so the default backend (which can differ per
    # platform) must not be allowed to pick an interactive one.
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np

    # Enough points that the exported PNG's base64 payload spans multiple
    # WS/stdout chunks (see server.lua's _reassemble_stdout why-comment) —
    # this scenario exists specifically to exercise that reassembly.
    x_vals = np.linspace(0, 20, 4000)
    fig, ax = plt.subplots(figsize=(8, 5), dpi=150)
    ax.plot(x_vals, np.sin(x_vals) * np.cos(x_vals * 3))
    ax.set_title("dense plot for chunked-stdout coverage")
    ax
    return


if __name__ == "__main__":
    app.run()
