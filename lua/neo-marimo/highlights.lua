local M = {}

M.ns_border = vim.api.nvim_create_namespace("neo_marimo_border")
M.ns_output = vim.api.nvim_create_namespace("neo_marimo_output")

function M.setup()
  -- Cell border colors by type
  vim.api.nvim_set_hl(0, "MarimoCellPythonBorder", { fg = "#7E9CD8", bold = true })
  vim.api.nvim_set_hl(0, "MarimoCellMarkdownBorder", { fg = "#76946A", bold = true })
  vim.api.nvim_set_hl(0, "MarimoCellSQLBorder", { fg = "#957FB8", bold = true })

  -- Cell label text inside borders
  vim.api.nvim_set_hl(0, "MarimoCellPythonLabel", { fg = "#7E9CD8" })
  vim.api.nvim_set_hl(0, "MarimoCellMarkdownLabel", { fg = "#76946A" })
  vim.api.nvim_set_hl(0, "MarimoCellSQLLabel", { fg = "#957FB8" })

  -- Status indicators
  vim.api.nvim_set_hl(0, "MarimoStatusRunning", { fg = "#FFA066", bold = true })
  vim.api.nvim_set_hl(0, "MarimoStatusError", { fg = "#E82424", bold = true })
  vim.api.nvim_set_hl(0, "MarimoStatusIdle", { link = "Comment" })

  -- Output text
  vim.api.nvim_set_hl(0, "MarimoOutputText", { link = "Comment" })
  vim.api.nvim_set_hl(0, "MarimoOutputError", { fg = "#E82424" })

  -- Cell index / name label
  vim.api.nvim_set_hl(0, "MarimoCellIndex", { fg = "#717C7C", italic = true })

  -- Disabled cell
  vim.api.nvim_set_hl(0, "MarimoCellDisabled", { fg = "#54546D", italic = true })
end

-- Returns {border_hl, label_hl} for a given cell type
function M.type_hls(cell_type)
  if cell_type == "markdown" then
    return "MarimoCellMarkdownBorder", "MarimoCellMarkdownLabel"
  elseif cell_type == "sql" then
    return "MarimoCellSQLBorder", "MarimoCellSQLLabel"
  else
    return "MarimoCellPythonBorder", "MarimoCellPythonLabel"
  end
end

return M
