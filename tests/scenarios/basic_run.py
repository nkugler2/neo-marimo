import marimo

__generated_with = "0.19.4"
app = marimo.App()


@app.cell
def _():
    x = 1 + 1
    x
    return (x,)


@app.cell
def _(x):
    y = x * 10
    y
    return (y,)


if __name__ == "__main__":
    app.run()
