import marimo

__generated_with = "0.19.4"
app = marimo.App()


@app.cell
def _():
    import marimo as mo
    return (mo,)


@app.cell
def _(mo):
    slider = mo.ui.slider(0, 10, value=5, label="N")
    slider
    return (slider,)


@app.cell
def _(slider):
    doubled = slider.value * 2
    doubled
    return (doubled,)


if __name__ == "__main__":
    app.run()
