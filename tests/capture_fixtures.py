#!/usr/bin/env python
"""Capture marimo's real serialized HTML for the neo-marimo render tests.

Runs every mo.ui widget / layout / nested combo through `_repr_html_()` and
writes one fixture file per case under tests/fixtures/<marimo major.minor>/.
The fixtures are committed so the Lua tests run without Python or marimo
installed. Re-run this script (and re-commit) when bumping the supported
marimo version:

    ~/.pyenv/versions/3.12.10/envs/MyMainTestingPython/bin/python \
        tests/capture_fixtures.py

Cases that need optional libraries (pandas/altair/plotly) are skipped with a
notice when the library is missing, so a minimal env still captures the core
widget set.
"""

from __future__ import annotations

import sys
from pathlib import Path

import marimo as mo

OUT_DIR = (
    Path(__file__).parent
    / "fixtures"
    / ".".join(mo.__version__.split(".")[:2])
)


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    cases: dict[str, object] = {}

    # ── plain widgets ────────────────────────────────────────────────────
    cases["slider"] = mo.ui.slider(0, 10, value=5, label="Slider 0-10")
    cases["range_slider"] = mo.ui.range_slider(
        0, 100, value=(20, 80), label="Range 0-100"
    )
    cases["checkbox"] = mo.ui.checkbox(label="Enable option", value=True)
    cases["switch"] = mo.ui.switch(label="A switch", value=False)
    cases["text"] = mo.ui.text(value="hello", label="Text input")
    cases["text_area"] = mo.ui.text_area(
        value="multi-line\ntext", label="Text area"
    )
    cases["number"] = mo.ui.number(value=3.14, label="A number")
    cases["date"] = mo.ui.date(label="Pick a date")
    cases["dropdown"] = mo.ui.dropdown(
        options=["apple", "banana", "cherry"], value="banana", label="Fruit"
    )
    cases["multiselect"] = mo.ui.multiselect(
        options=["a", "b", "c"], value=["a"], label="Pick many"
    )
    cases["radio"] = mo.ui.radio(
        options=["red", "green", "blue"], value="green", label="Color"
    )
    cases["button"] = mo.ui.button(label="Click me", kind="neutral")
    cases["run_button"] = mo.ui.run_button(label="Run action")
    cases["file"] = mo.ui.file(label="Upload file", multiple=True)
    cases["refresh"] = mo.ui.refresh(
        options=["1m", "30m", "1h"], default_interval="1m"
    )
    cases["array"] = mo.ui.array(
        [
            mo.ui.text(value="A"),
            mo.ui.number(value=1),
            mo.ui.checkbox(label="Check", value=False),
        ]
    )
    cases["form"] = mo.ui.text(value="x").form()

    # ── markdown / html ──────────────────────────────────────────────────
    cases["md_simple"] = mo.md("Simple text in a tab")
    cases["md_rich"] = mo.md(
        "# Heading\n\nSome *italic* and **bold** and `code`.\n\n"
        "- one\n- two\n\n```python\nprint('hi')\n```"
    )
    cases["callout"] = mo.md("note body").callout(kind="info")

    # ── layouts (no df dependency) ───────────────────────────────────────
    slider = mo.ui.slider(0, 10, value=5, label="Slider")
    check = mo.ui.checkbox(label="Check", value=True)
    txt = mo.ui.text(value="hi", label="Text")
    cases["vstack_widgets"] = mo.vstack([slider, check, txt])
    cases["hstack_widgets"] = mo.hstack([slider, check])
    cases["hstack_md"] = mo.hstack([mo.md("Left **col**"), mo.md("Right col")])
    cases["tabs_simple"] = mo.ui.tabs(
        {"A": mo.vstack([slider, check]), "B": mo.md("hello")}
    )
    cases["accordion"] = mo.accordion(
        {"Section 1": mo.md("body one"), "Section 2": slider}
    )
    cases["nested_stacks"] = mo.vstack(
        [mo.hstack([slider, check]), mo.md("below the row"), txt]
    )

    # ── pandas-dependent cases ───────────────────────────────────────────
    try:
        import pandas as pd

        df = pd.DataFrame(
            {
                "a": [1, 2, 3, 4, 5],
                "b": [5, 4, 3, 2, 1],
                "c": [10, 15, 10, 20, 25],
                "cat": ["x", "y", "x", "y", "x"],
            }
        )
        cases["table"] = mo.ui.table(df)
        cases["dataframe_widget"] = mo.ui.dataframe(df)
        cases["data_explorer"] = mo.ui.data_explorer(df)
        cases["df_as_html"] = mo.as_html(df)
        # Shape 3 from dataframe.lua: raw pandas to_html (no marimo wrapper).
        cases["plain_html_table"] = df.to_html()
        # The cell-4 shape from notebooks/notebook.py: tabs containing a
        # table next to widget stacks. THE regression case for the
        # "dataframe hijacks the whole cell" bug.
        cases["tabs_with_table"] = mo.ui.tabs(
            {
                "Selectors": mo.vstack([slider, check]),
                "Tables": mo.vstack([mo.ui.table(df)]),
                "Refresh": mo.ui.refresh(options=["1m"], default_interval="1m"),
            }
        )
        cases["tabs_mixed"] = mo.ui.tabs(
            {"Markdown": mo.md("Simple text in a tab"), "Data": df}
        )
    except ImportError:
        print("skip: pandas not installed — table fixtures not captured")
        df = None

    # ── chart widgets (placeholder-rendered, but must parse) ────────────
    if df is not None:
        ui_altair = None
        ui_plotly = None
        try:
            import altair as alt

            ui_altair = mo.ui.altair_chart(
                alt.Chart(df).mark_point().encode(x="a", y="b")
            )
            cases["altair_chart"] = ui_altair
        except ImportError:
            print("skip: altair not installed")
        try:
            import plotly.express as px

            ui_plotly = mo.ui.plotly(px.scatter(df, x="a", y="b"))
            cases["plotly"] = ui_plotly
        except ImportError:
            print("skip: plotly not installed")

        # The full cell-4 construct from notebooks/notebook.py: every widget
        # family mixed inside one mo.ui.tabs. The heaviest regression case.
        if ui_altair is not None and ui_plotly is not None:
            cases["notebook_cell4"] = mo.ui.tabs(
                {
                    "Buttons": mo.vstack(
                        [
                            mo.ui.button(label="Click me", kind="neutral"),
                            mo.ui.run_button(label="Run action"),
                        ]
                    ),
                    "Selectors": mo.vstack(
                        [
                            mo.ui.checkbox(label="Enable option", value=True),
                            mo.ui.date(label="Pick a date"),
                            mo.ui.dropdown(
                                options=["apple", "banana", "cherry"],
                                value="banana",
                                label="Fruit",
                            ),
                            mo.ui.radio(
                                options=["red", "green", "blue"],
                                value="green",
                                label="Color",
                            ),
                            mo.ui.number(value=3.14, label="A number"),
                            mo.ui.slider(0, 10, value=5, label="Slider 0-10"),
                            mo.ui.range_slider(
                                0, 100, value=(20, 80), label="Range 0-100"
                            ),
                        ]
                    ),
                    "Text & File": mo.vstack(
                        [
                            mo.ui.text(value="hello", label="Text input"),
                            mo.ui.text_area(
                                value="multi-line\ntext", label="Text area"
                            ),
                            mo.ui.file(label="Upload file", multiple=True),
                        ]
                    ),
                    "Tables": mo.vstack(
                        [mo.ui.table(df), mo.ui.dataframe(df)]
                    ),
                    "Charts (UI)": mo.vstack([ui_altair, ui_plotly]),
                    "Refresh": mo.ui.refresh(
                        options=["1m", "30m", "1h"], default_interval="1m"
                    ),
                }
            )

    # ── images ───────────────────────────────────────────────────────────
    cases["html_svg_inline"] = mo.Html(
        "<svg width=140 height=80 xmlns='http://www.w3.org/2000/svg'>"
        "<rect x='5' y='5' width='130' height='70' fill='#eef'/></svg>"
    )
    # Tiny valid 1x1 PNG so the data-URI path has a fixture.
    png_b64 = (
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4"
        "2mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    )
    cases["html_img_datauri"] = mo.Html(
        f"<img alt='png test' src='data:image/png;base64,{png_b64}'/>"
    )

    for name, obj in sorted(cases.items()):
        html = obj if isinstance(obj, str) else obj._repr_html_()
        path = OUT_DIR / f"{name}.html"
        path.write_text(html, encoding="utf-8")
        print(f"wrote {path.relative_to(Path(__file__).parent.parent)}"
              f" ({len(html)} bytes)")

    print(f"\n{len(cases)} fixtures captured for marimo {mo.__version__}")


if __name__ == "__main__":
    sys.exit(main())
