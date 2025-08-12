-- Auto-init with defaults so commands exist even without explicit setup().
-- Users can still call require("renamer").setup({ ... }) later to override.
pcall(function()
  require("renamer").setup()
end)
