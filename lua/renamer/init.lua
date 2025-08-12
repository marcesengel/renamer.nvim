-- lua/renamer/init.lua
-- renamer.nvim — batch-rename/move files from inside Neovim using ripgrep
-- Lazy-native: users configure with:
--   { "marcesengel/renamer.nvim", main = "renamer", opts = { ... }, cmd = {...}, keys = {...} }

local M = {}

-- ==============================
-- Config (override via setup{})
-- ==============================
local cfg = {
  -- Base ripgrep command used to list files. We append "-g <pattern>" per pattern.
  rg_base = "rg --files --color=never",
  -- Default dry-run (preview) mode for newly opened rename buffers.
  dry_run = false,
}

-- Track whether we’ve registered user commands already
local _commands_ready = false

-- ==============================
-- Small utilities
-- ==============================
---@diagnostic disable: undefined-field
local uv = vim.uv or vim.loop -- 0.10+: vim.uv, older: vim.loop
---@diagnostic enable: undefined-field

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function is_dir(p) return vim.fn.isdirectory(p) == 1 end
local function file_exists(p) return vim.fn.filereadable(p) == 1 end
local function abs(p) return vim.fn.fnamemodify(p, ":p") end
local function parent_dir(p) return vim.fn.fnamemodify(p, ":h") end

local function ensure_parent(to)
  local parent = parent_dir(to)
  if parent ~= "" and parent ~= "." and not is_dir(parent) then
    vim.fn.mkdir(parent, "p")
  end
end

local function dir_is_empty(p)
  if not is_dir(p) then return false end
  if uv and type(uv.fs_scandir) == "function" and type(uv.fs_scandir_next) == "function" then
    local handle = uv.fs_scandir(p)
    if not handle then return false end
    local name = uv.fs_scandir_next(handle)
    return name == nil
  else
    local ok, entries = pcall(vim.fn.readdir, p)
    return ok and #entries == 0
  end
end

local function rmdir_empty(p)
  if uv and type(uv.fs_rmdir) == "function" then
    local r = uv.fs_rmdir(p)
    return r == 0 or r == true
  end
  return vim.fn.delete(p, "d") == 0
end

-- remove empty parent directories up to (but NOT including) stop_dir (defaults to CWD)
local function prune_empty_parents(start_dir, stop_dir)
  local removed = 0
  local cur = abs(start_dir)
  local stop = abs(stop_dir or vim.fn.getcwd())
  while cur ~= "" do
    if cur == stop then break end
    if dir_is_empty(cur) then
      if not rmdir_empty(cur) then break end
      removed = removed + 1
      local next_cur = abs(parent_dir(cur))
      if next_cur == cur then break end -- reached filesystem root
      cur = next_cur
    else
      break
    end
  end
  return removed
end

local function unique_tmp_path(sibling_path)
  local dir   = parent_dir(sibling_path)
  local base  = vim.fn.fnamemodify(sibling_path, ":t")
  -- prefer high-res time; fall back to os.time + random
  local nonce = (uv and uv.hrtime and uv.hrtime())
      or (os.time() * 1e9 + math.random(1, 1e6))
  return string.format("%s/.%s.mv.%s.tmp", dir, base, tostring(nonce))
end

local function build_rg_cmd(patterns)
  local cmd = cfg.rg_base
  if patterns and #patterns > 0 then
    for _, patt in ipairs(patterns) do
      if patt and patt ~= "" then
        cmd = cmd .. " -g " .. vim.fn.shellescape(patt)
      end
    end
  end
  return cmd
end

local function list_files(patterns)
  local out = vim.fn.systemlist(build_rg_cmd(patterns))
  if vim.v.shell_error ~= 0 then
    vim.notify("renamer: ripgrep command failed. Check rg_base/patterns.", vim.log.levels.ERROR)
    return {}
  end
  return out
end

-- robust move with fallbacks, including cross-device copy+unlink
local function move_path(src, dst)
  -- try plain rename first (fast path)
  local ok = os.rename(src, dst)
  if ok then return true end

  -- try libuv if present
  if uv and type(uv.fs_rename) == "function" then
    local r = uv.fs_rename(src, dst)
    if r == 0 or r == true then return true end
    -- cross-device fallback if copy available
    if uv.fs_copyfile then
      local c = uv.fs_copyfile(src, dst)
      if c == 0 or c == true then
        if uv.fs_unlink then uv.fs_unlink(src) else os.remove(src) end
        return true
      end
    end
    return false, "rename failed (libuv)"
  end

  -- final fallback: Lua copy (chunked) + remove
  local inF = io.open(src, "rb"); if not inF then return false, "open src failed" end
  local outF = io.open(dst, "wb"); if not outF then
    inF:close(); return false, "open dst failed"
  end
  while true do
    local chunk = inF:read(65536)
    if not chunk then break end
    outF:write(chunk)
  end
  inF:close()
  outF:close()
  os.remove(src)
  return true
end

-- ==============================
-- Core buffer open / lifecycle
-- ==============================
local function open_buf_with(lines, opts)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, "renamer")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Make it an acwrite buffer so :w triggers BufWriteCmd
  vim.bo[buf].buftype         = "acwrite"
  vim.bo[buf].bufhidden       = "hide"
  vim.bo[buf].swapfile        = false
  vim.bo[buf].filetype        = "renamer"

  -- Store the original list for diffing
  vim.b[buf].renamer_original = vim.deepcopy(lines or {})
  -- Buffer-local dry_run overrides global default (nil → use cfg.dry_run)
  vim.b[buf].renamer_dry_run  = opts and opts.dry_run or nil

  -- Command to toggle buffer-local dry-run
  vim.api.nvim_buf_create_user_command(buf, "RenamerToggleDryRun", function()
    local cur = vim.b[buf].renamer_dry_run
    if cur == nil then cur = cfg.dry_run end
    vim.b[buf].renamer_dry_run = not cur
    vim.notify("renamer: dry_run = " .. tostring(vim.b[buf].renamer_dry_run))
  end, {})

  -- Intercept writes to apply renames
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function(args)
      -- Fetch buffer-local dry_run value (fallback to cfg)
      local dry_run = vim.b[args.buf].renamer_dry_run
      if dry_run == nil then dry_run = cfg.dry_run end

      -- Read current lines, trim trailing spaces; disallow blanks
      local new_lines_raw = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
      local new_lines, blank_at = {}, nil
      for i, l in ipairs(new_lines_raw) do
        local s = (l or ""):gsub("%s+$", "")
        if s == "" then blank_at = blank_at or i else table.insert(new_lines, s) end
      end
      if blank_at then
        vim.notify(("renamer: empty line at %d; one path per line required."):format(blank_at), vim.log.levels.ERROR)
        return
      end

      local old_lines = vim.b[args.buf].renamer_original or {}
      if #new_lines ~= #old_lines then
        vim.notify(("renamer: line count changed (old=%d new=%d). One line per original file, please.")
          :format(#old_lines, #new_lines), vim.log.levels.ERROR)
        return
      end

      -- Build renames and validate
      local pairs, to_set, conflicts = {}, {}, {}
      local from_set = {}
      for _, f in ipairs(old_lines) do from_set[f] = true end

      for i = 1, #old_lines do
        local from, to = old_lines[i], new_lines[i]
        if from ~= to then
          if to_set[to] then table.insert(conflicts, to) end
          to_set[to] = true
          table.insert(pairs, { from = from, to = to })
        end
      end

      if #pairs == 0 then
        vim.notify("renamer: nothing to do")
        -- mark as written to clear the modified flag
        vim.bo[args.buf].modified = false
        return
      end

      if #conflicts > 0 then
        vim.notify("renamer: duplicate destinations: " .. table.concat(conflicts, ", "), vim.log.levels.ERROR)
        return
      end

      -- Validate sources and accidental overwrite
      local overwrite_conflicts = {}
      for _, m in ipairs(pairs) do
        if not file_exists(m.from) then
          vim.notify("renamer: source missing: " .. m.from, vim.log.levels.ERROR)
          return
        end
        if m.to ~= m.from and file_exists(m.to) and not from_set[m.to] then
          -- Destination exists and isn't scheduled to move away → don't clobber
          table.insert(overwrite_conflicts, m.to)
        end
      end
      if #overwrite_conflicts > 0 then
        vim.notify("renamer: destination already exists (would overwrite): " ..
          table.concat(overwrite_conflicts, ", "), vim.log.levels.ERROR)
        return
      end

      -- If dry-run: preview and stop
      if dry_run then
        local preview = {}
        for _, m in ipairs(pairs) do table.insert(preview, m.from .. " -> " .. m.to) end
        vim.cmd("new")
        vim.api.nvim_buf_set_lines(0, 0, -1, false, preview)
        vim.notify(("renamer: dry run (%d change%s)")
          :format(#pairs, #pairs == 1 and "" or "s"))
        -- mark as written so the buffer isn't left modified
        vim.bo[args.buf].modified = false
        return
      end

      -- Two-phase rename to avoid cycles/collisions:
      -- Phase A: for any pair where `to` is also a source (and != from), move `from` -> temp
      -- Phase B: move (temp|from) -> to
      local staged, stageA, errors = {}, {}, {}

      -- Decide which need staging
      local needs_stage = {}
      for _, m in ipairs(pairs) do
        if (m.to ~= m.from) and from_set[m.to] then
          needs_stage[m.from] = true
        end
      end

      -- Phase A
      for _, m in ipairs(pairs) do
        if needs_stage[m.from] then
          local tmp = unique_tmp_path(m.from)
          ensure_parent(tmp)
          local ok, msg = move_path(m.from, tmp)
          if not ok then
            table.insert(errors, { m = m, phase = "A", err = msg or "rename failed" })
          else
            staged[m.from] = tmp
            table.insert(stageA, { tmp = tmp, from = m.from })
          end
        end
      end

      if #errors > 0 then
        vim.notify(("renamer: failed during staging. First: %s -> %s (%s)")
          :format(errors[1].m.from, errors[1].m.to, errors[1].err), vim.log.levels.ERROR)
        -- Best-effort rollback of successful A moves
        for _, s in ipairs(stageA) do
          if file_exists(s.tmp) and not file_exists(s.from) then
            pcall(move_path, s.tmp, s.from)
          end
        end
        return
      end

      -- Phase B
      local phaseB_errors = {}
      for _, m in ipairs(pairs) do
        local cur_from = staged[m.from] or m.from
        ensure_parent(m.to)
        local ok, msg = move_path(cur_from, m.to)
        if not ok then
          table.insert(phaseB_errors, { m = m, err = msg or "rename failed" })
        end
      end

      if #phaseB_errors > 0 then
        -- Best-effort rollback: for any staged item not moved, try to restore
        for _, s in ipairs(stageA) do
          if file_exists(s.tmp) and not file_exists(s.from) then
            pcall(move_path, s.tmp, s.from)
          end
        end
        local e = phaseB_errors[1]
        vim.notify(("renamer: failed to complete renames. First: %s -> %s (%s)")
          :format(e.m.from, e.m.to, e.err), vim.log.levels.ERROR)
        return
      end

      -- Success: update the stored original list so subsequent writes work
      vim.b[args.buf].renamer_original = new_lines
      -- mark as written
      vim.bo[args.buf].modified = false

      -- === NEW: prune empty directories left behind (sources' parents) ===
      local cleanup_root = abs(vim.fn.getcwd())
      local parent_set = {}
      for _, m in ipairs(pairs) do
        parent_set[abs(parent_dir(m.from))] = true
      end
      local removed = 0
      for dir, _ in pairs(parent_set) do
        removed = removed + prune_empty_parents(dir, cleanup_root)
      end
      if removed > 0 then
        vim.notify(("renamer: applied %d rename%s; removed %d empty dir%s")
          :format(#pairs, #pairs == 1 and "" or "s", removed, removed == 1 and "" or "s"))
      else
        vim.notify(("renamer: applied %d rename%s")
          :format(#pairs, #pairs == 1 and "" or "s"))
      end
    end,
  })

  vim.api.nvim_set_current_buf(buf)
end

-- ==============================
-- Public API
-- ==============================
--- Open a rename buffer.
--- @param patterns string[]|nil  list of ripgrep -g patterns (nil = all files)
--- @param opts table|nil         { dry_run = boolean } buffer-local override
function M.open(patterns, opts)
  local files = list_files(patterns)
  if #files == 0 then
    vim.notify("renamer: no files from ripgrep", vim.log.levels.WARN)
    return
  end
  open_buf_with(files, opts)
end

-- Define commands exactly once (idempotent)
local function ensure_commands()
  if _commands_ready then return end

  vim.api.nvim_create_user_command("Renamer", function(cmd)
    local opts = cmd.bang and { dry_run = true } or nil
    M.open(nil, opts)
  end, { nargs = 0, bang = true })

  vim.api.nvim_create_user_command("RenamerPattern", function(cmd)
    local arg = table.concat(cmd.fargs or {}, " ")
    local function to_list(s)
      local pats = {}
      for part in s:gmatch("[^,]+") do table.insert(pats, trim(part)) end
      return pats
    end

    if arg == nil or trim(arg) == "" then
      vim.ui.input({ prompt = "ripgrep -g pattern(s), comma-separated: " }, function(p)
        if p and trim(p) ~= "" then
          M.open(to_list(p), nil)
        else
          vim.notify("renamer: pattern empty — aborted", vim.log.levels.WARN)
        end
      end)
    else
      M.open(to_list(arg), nil)
    end
  end, { nargs = "*" })

  _commands_ready = true
end

function M.setup(user_cfg)
  cfg = vim.tbl_deep_extend("force", cfg, user_cfg or {})
  ensure_commands() -- define :Renamer / :RenamerPattern once
end

return M
