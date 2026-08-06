-- T7 corpus manifest (docs/plan-testing.md T7). One entry per notebook under
-- tests/corpus/<name>.py, keyed by that same <name>. A notebook dropped into
-- tests/corpus/ with NO entry here still runs — tests/corpus.lua's
-- M.entry() synthesizes a default ("exploratory", all levels) and prints a
-- one-line notice — so the "drop a file in, zero wiring" contract holds
-- before anyone edits this file.
--
-- Fields:
--   source  — provenance URL (or "hand-written, modeled on ..." for a
--             locally-authored substitute, if network access ever forces one
--             — none of the entries below needed that).
--   license — the upstream license, since anything copied from marimo's own
--             repo is Apache-2.0, not this project's license.
--   mode    — "strict": regression — every level this entry runs must pass,
--             every time. "exploratory": gaps (unsupported widgets, HTML the
--             output renderer punts on, unknown ops, parse warnings) are
--             collected into the CORPUS GAPS report instead of failing the
--             suite. Flip a notebook to "strict" once its gap report is
--             clean — that flip IS the "feature is now supported" signal.
--   levels  — which of {1, 2, 3} to run. Default (and every notebook here)
--             is all three; level 3 only actually replays anything once a
--             transcript has been recorded via `make transcripts
--             CORPUS=<name>` — see tests/corpus.lua's M.transcript_path.
--             That recording is gitignored (tests/corpus/transcripts/),
--             so on a fresh clone level 3 self-skips with a notice, which
--             is the expected steady state for most corpus entries
--             (docs/plan-testing.md T7's "Known risk" paragraph: transcript
--             determinism is not required for corpus notebooks).

return {
  -- marimo's own built-in "intro" tutorial (`marimo tutorial intro`):
  -- markdown-heavy, an accordion, a couple of plain sliders/dropdown, no
  -- external dependencies. Every construct it uses (md, accordion, callout,
  -- slider, dropdown) already has a dedicated renderer, so this is a
  -- regression anchor for the "does our basic tutorial-shaped notebook still
  -- render" question.
  intro_tutorial = {
    source = "https://raw.githubusercontent.com/marimo-team/marimo/main/marimo/_tutorials/intro.py",
    license = "Apache-2.0 (marimo-team/marimo)",
    mode = "strict",
    levels = { 1, 2, 3 },
  },

  -- examples/ui/code_editor.py. Picked deliberately (not just "a widget
  -- example", and verified against a real recorded transcript before being
  -- chosen — `mo.ui.run_button` was tried first and turned out to reuse
  -- `mo.ui.button`'s own `<marimo-button>` custom element under the hood, so
  -- it was already fully supported): `mo.ui.code_editor` renders as
  -- `<marimo-code-editor>`, which is genuinely absent from both
  -- tree_render.lua's WIDGET_TAGS and PLACEHOLDER_TAGS, so it falls through
  -- to the generic "unknown marimo element" path and hits widgets.lua's
  -- render_unknown fallback. This is the corpus's live example of the
  -- exploratory gap-report acceptance criterion: a real, unmodified,
  -- third-party notebook with an unsupported widget, producing a CORPUS
  -- GAPS line instead of a red suite. Confirmed via
  -- `make transcripts CORPUS=widgets_code_editor` + a level-3 replay
  -- (tests/corpus/transcripts/, not committed — see that field's own note).
  widgets_code_editor = {
    source = "https://raw.githubusercontent.com/marimo-team/marimo/main/examples/ui/code_editor.py",
    license = "Apache-2.0 (marimo-team/marimo)",
    mode = "exploratory",
    levels = { 1, 2, 3 },
  },

  -- examples/ui/table.py: mo.ui.table over plain list-of-dicts data (no
  -- pandas/etc. dependency), including a 200-row paginated table. Renders
  -- through tree_render.lua's dedicated <marimo-table> path
  -- (dataframe.extract_from_html / render_inline), which is fully
  -- supported — the "dataframe/plotting" regression anchor.
  dataframe_table = {
    source = "https://raw.githubusercontent.com/marimo-team/marimo/main/examples/ui/table.py",
    license = "Apache-2.0 (marimo-team/marimo)",
    mode = "strict",
    levels = { 1, 2, 3 },
  },

  -- examples/markdown/admonitions.py: pymdownx-style `/// admonition |
  -- Title` blocks inside mo.md(). markdown.lua was never explicitly built
  -- against that syntax (it targets marimo's own md-to-HTML output, so the
  -- admonition block arrives already-rendered HTML — this notebook is here
  -- specifically to prove that one way or the other), so this stays
  -- exploratory until a human reads its gap report and confirms.
  markdown_admonitions = {
    source = "https://raw.githubusercontent.com/marimo-team/marimo/main/examples/markdown/admonitions.py",
    license = "Apache-2.0 (marimo-team/marimo)",
    mode = "exploratory",
    levels = { 1, 2 }, -- pure presentation, no reactive widgets worth a kernel spawn for level 3
  },
}
