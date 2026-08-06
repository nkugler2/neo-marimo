import marimo

__generated_with = "0.19.4"
app = marimo.App()


@app.cell
def _():
    1 / 0
    return


if __name__ == "__main__":
    app.run()
