# renamer.nvim

Batch-rename and move files **from inside Neovim** using **ripgrep** to build the file list.  
Edit paths like regular text (or use case-aware `:%Subvert/.../.../g` via vim-abolish), then `:w` to apply.  
Safe by default: two-phase renames avoid cycles, parents are created automatically, and there’s a built-in **dry-run**.

---

## Features

- 📁 Project-wide file list via `rg --files` (respects `.gitignore`, `.ignore`, `.rgignore`)
- 🎯 Optional `-g` globs (single or comma-separated) to target subsets (`**/*.ts,src/**`)
- ✍️ Edit in a buffer; one line = one file path
- 🛡️ Safety:
  - Preview mode (**dry-run**) with `:Renamer!` or `:RenamerToggleDryRun`
  - Duplicate destination detection
  - No silent overwrites (refuses if destination exists and isn’t being moved)
  - **Two-phase** (temp) moves to handle cycles
  - Auto-create parent directories

---

## Requirements

- Neovim 0.10+
- [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) in `$PATH`

---

## Install (lazy.nvim)

```lua
-- lua/plugins/renamer.lua
return {
  "marcesengel/renamer.nvim",
  opts = {
    rg_base = "rg --files --color=never",
    dry_run = false,
  },
  cmd = { "Renamer", "RenamerPattern" },
  keys = {
    { "<leader>br", "<cmd>Renamer<cr>",         desc = "Renamer: all files via ripgrep" },
    { "<leader>bR", "<cmd>RenamerPattern<cr>",  desc = "Renamer: ripgrep -g pattern(s)" },
  },
}
```

---

## Commands

- `:Renamer`  
  Open a buffer with **all files** from `rg --files`.

- `:Renamer!`  
  Same as above, but the buffer starts in **dry-run** (preview) mode.

- `:RenamerPattern {patterns}`  
  Open a buffer filtered by ripgrep `-g` globs.  
  Accepts **comma-separated** patterns, e.g.  
  `:RenamerPattern **/*.ts,**/*.tsx,src/**`  
  If run without args, it prompts for patterns.

- `:RenamerToggleDryRun` (buffer-local)  
  Toggle preview mode for the current renamer buffer.

---

## Usage

1) Open a list:
   - All files: `:Renamer` (or `<leader>br`)  
   - Filtered: `:RenamerPattern **/*.ts,src/**` (or `<leader>bR`)

2) Edit paths like text. Each **line corresponds to the same index** in the original list.  
   You can move between directories, rename files, or change extensions.

3) (Optional) Case-aware bulk rename with **vim-abolish**:
   ```vim
   :%Subvert/oldname/newname/g
   ```
   This updates `oldname`, `old_name`, `old-name`, `OldName`, `OLDNAME`, `oldName`, etc.

4) Save to apply:
   ```vim
   :w
   ```
   - In **dry-run**, you’ll see a preview buffer: `FROM -> TO`
   - Toggle off preview (`:RenamerToggleDryRun`) and `:w` again to apply

---

## Configuration

```lua
require("renamer").setup({
  rg_base = "rg --files --color=never", -- base ripgrep command; plugin appends -g per pattern
  dry_run = false,                      -- default for new buffers (can toggle in-buffer)
})
```

**Notes:**
- `rg --files` respects `.gitignore`, `.ignore`, `.rgignore`, and includes **untracked** files (if not ignored).

---

## Safety & internals

- **No overwrites**: if a destination already exists and isn’t being moved away, the operation aborts with a clear message.
- **Two-phase cycle handling**: A→B and B→A moves are staged through unique temporary names.
- **One line per file**: The plugin validates that the edited buffer has the **same number of lines** as the original list.

---

## Troubleshooting

- **“line count changed … one line per original file”**  
  Don’t add/delete lines. Keep one path per original file. Use substitutions (`:%s` / `:%Subvert`) or edit in place.

- **“duplicate destinations …”**  
  Two outputs point to the same path. Fix duplicates or change targets.

- **Nothing happens on `:w`**  
  You might be in **dry-run**. `:RenamerToggleDryRun`, then `:w`.

- **Huge repos feel slow**  
  Use `:RenamerPattern` with globs (`src/**`, `**/*.ts`) to limit scope.

---

## FAQ

**Does it rewrite imports/refs?**  
No. This only renames/moves files on disk. Use LSP or specialized tools to refactor code references.

**Does it support directories too?**  
`rg --files` lists files. You can move files into new directories by editing their paths; parents are created automatically.

**Windows?**  
Works in Neovim on Windows. Ensure `rg` is available and your shell is set. Cross-device fallback helps when drives differ.

---

## Integrations

- **vim-abolish** (recommended)  
  Install `tpope/vim-abolish` and use `:%Subvert/old/new/g` in the renamer buffer for case-aware mass renames.

---

## License

MIT © Marces Engel

