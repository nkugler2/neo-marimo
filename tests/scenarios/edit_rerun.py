import marimo

__generated_with = "0.19.4"
app = marimo.App()


@app.cell
def _():
    n = 1
    n
    return (n,)


if __name__ == "__main__":
    app.run()
