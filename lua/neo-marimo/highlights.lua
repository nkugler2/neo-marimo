local M = {}

M.ns_border = vim.api.nvim_create_namespace("neo_marimo_border")
M.ns_output = vim.api.nvim_create_namespace("neo_marimo_output")

function M.setup()
  -- Cell border colors by type
  vim.api.nvim_set_hl(0, "MarimoCellPythonBorder", { fg = "#7E9CD8", bold = true })
  vim.api.nvim_set_hl(0, "MarimoCellMarkdownBorder", { fg = "#76946A", bold = true })
  vim.api.nvim_set_hl(0, "MarimoCellSQLBorder", { fg = "#957FB8", bold = true })
  vim.api.nvim_set_hl(0, "MarimoCellMarimoBorder", { fg = "#E6C384", bold = true })

  -- Cell label text inside borders
  vim.api.nvim_set_hl(0, "MarimoCellPythonLabel", { fg = "#7E9CD8" })
  vim.api.nvim_set_hl(0, "MarimoCellMarkdownLabel", { fg = "#76946A" })
  vim.api.nvim_set_hl(0, "MarimoCellSQLLabel", { fg = "#957FB8" })
  vim.api.nvim_set_hl(0, "MarimoCellMarimoLabel", { fg = "#E6C384" })

  -- Status indicators
  vim.api.nvim_set_hl(0, "MarimoStatusRunning", { fg = "#FFA066", bold = true })
  vim.api.nvim_set_hl(0, "MarimoStatusError", { fg = "#E82424", bold = true })
  vim.api.nvim_set_hl(0, "MarimoStatusOk", { fg = "#76946A", bold = true })
  vim.api.nvim_set_hl(0, "MarimoStatusIdle", { link = "Comment" })

  -- Output text
  vim.api.nvim_set_hl(0, "MarimoOutputText", { link = "Comment" })
  vim.api.nvim_set_hl(0, "MarimoOutputError", { fg = "#E82424" })

  -- Cell index / name label
  vim.api.nvim_set_hl(0, "MarimoCellIndex", { fg = "#717C7C", italic = true })

  -- Disabled cell
  vim.api.nvim_set_hl(0, "MarimoCellDisabled", { fg = "#54546D", italic = true })

  -- ── Phase 8.1 markdown rendering ─────────────────────────────────────────
  -- Heading levels (1 = largest). Link to treesitter `@markup.heading.N` when
  -- the user's colorscheme defines them; otherwise fall back to a sensible
  -- default so the output is visible everywhere.
  vim.api.nvim_set_hl(0, "MarimoMarkdownH1", { fg = "#FFA066", bold = true })
  vim.api.nvim_set_hl(0, "MarimoMarkdownH2", { fg = "#E6C384", bold = true })
  vim.api.nvim_set_hl(0, "MarimoMarkdownH3", { fg = "#76946A", bold = true })
  vim.api.nvim_set_hl(0, "MarimoMarkdownH4", { fg = "#7E9CD8", bold = true })
  vim.api.nvim_set_hl(0, "MarimoMarkdownH5", { fg = "#957FB8", bold = true })
  vim.api.nvim_set_hl(0, "MarimoMarkdownH6", { fg = "#717C7C", bold = true })

  vim.api.nvim_set_hl(0, "MarimoMarkdownBullet", { fg = "#7E9CD8" })
  vim.api.nvim_set_hl(0, "MarimoMarkdownBold", { fg = "#DCD7BA", bold = true })
  vim.api.nvim_set_hl(0, "MarimoMarkdownItalic", { fg = "#DCD7BA", italic = true })
  vim.api.nvim_set_hl(0, "MarimoMarkdownLink", { fg = "#7FB4CA", underline = true })
  vim.api.nvim_set_hl(0, "MarimoMarkdownInlineCode", { fg = "#FFA066", bg = "#2A2A37" })
  vim.api.nvim_set_hl(0, "MarimoMarkdownCode", { fg = "#C8C093", bg = "#1F1F28" })
  vim.api.nvim_set_hl(0, "MarimoMarkdownCodeBorder", { fg = "#54546D" })
  vim.api.nvim_set_hl(0, "MarimoMarkdownQuote", { fg = "#957FB8", italic = true })
  vim.api.nvim_set_hl(0, "MarimoMarkdownQuoteBorder", { fg = "#54546D" })
  vim.api.nvim_set_hl(0, "MarimoMarkdownRule", { fg = "#54546D" })

  -- ── Phase 8.3 widget rendering ───────────────────────────────────────────
  vim.api.nvim_set_hl(0, "MarimoWidgetLabel", { fg = "#7FB4CA" })
  vim.api.nvim_set_hl(0, "MarimoWidgetValue", { fg = "#E6C384", bold = true })
  vim.api.nvim_set_hl(0, "MarimoWidgetTrack", { fg = "#54546D" })
  vim.api.nvim_set_hl(0, "MarimoWidgetThumb", { fg = "#FFA066", bold = true })
  vim.api.nvim_set_hl(0, "MarimoWidgetButton", { fg = "#1F1F28", bg = "#7E9CD8", bold = true })
  vim.api.nvim_set_hl(0, "MarimoWidgetBoxBorder", { fg = "#54546D" })
  vim.api.nvim_set_hl(0, "MarimoWidgetTabActive", { fg = "#FFA066", bold = true, underline = true })
  vim.api.nvim_set_hl(0, "MarimoWidgetTabInactive", { fg = "#717C7C" })
end

-- Returns {border_hl, label_hl} for a given cell type
function M.type_hls(cell_type)
  if cell_type == "markdown" then
    return "MarimoCellMarkdownBorder", "MarimoCellMarkdownLabel"
  elseif cell_type == "sql" then
    return "MarimoCellSQLBorder", "MarimoCellSQLLabel"
  elseif cell_type == "marimo" then
    return "MarimoCellMarimoBorder", "MarimoCellMarimoLabel"
  else
    return "MarimoCellPythonBorder", "MarimoCellPythonLabel"
  end
end

return M
