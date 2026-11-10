# trailmap.nvim

Neovim plugin: ask a question about a codebase; an interactive AI agent (Claude Code or Codex) finds the code that answers it, and the plugin renders those line ranges as a file tree + highlighted source. User-facing docs: `README.md`.

## Layout

Single file: `lua/trailmap/init.lua`. No `plugin/` dir — nothing runs until `setup()`.

Top to bottom:

1. **Viewer** (pure UI, agent-agnostic)
   - `highlight` — treesitter highlighting for a snippet (currently unused leftover from the old snippet view; safe to delete).
   - `icon` — mini.icons → nvim-web-devicons → none.
   - `group` — snippets → `{ file = {{start, finish, why}} }` + sorted file list.
   - `mark_file` — extmarks (`TrailmapRange` line hl, `TrailmapSign` sign, `i/n` + `why` virt text) and buffer-local `]s` `[s` `<Tab>` `<S-Tab>` `<leader>ee` in the real source buffer.
   - `open(main, question, snippets, quit)` — builds a compacted dir tree in a scratch panel (`filetype=trailmap`) split left of `main`, wires panel keys, CursorMoved preview, `gq` quickfix. Returns `teardown()` which clears marks/keymaps from touched buffers and closes the panel **but not the tab**, so it can be re-rendered in place.
2. **Config + prompt** — `M.config`, `PROMPT` (contains `{{RESULT}}` placeholder, question appended at the end).
3. **Result handling** — `from_ai(data, cwd)` normalises paths (strips `./` and absolute cwd prefix), drops unreadable files, clamps ranges to file length. `decode` = safe JSON decode.
4. **Agents** — `agents.claude(prompt, result)` / `agents.codex(prompt, result)` return the argv for an *interactive* session. Adding an agent = add a function here; `:TrailmapAgent` completion picks it up.
5. **`M.ask(question)`** — orchestration:
   - temp dir via `tempname()`, result path `<dir>/result.json`
   - `tabnew` → `main` window; terminal split right (`width` fraction) running the agent via `jobstart(..., { term = true })`
   - terminal-mode `<C-h/j/k/l>` → `<cmd>wincmd x<cr>`; `BufEnter` on the terminal → `startinsert`
   - 500 ms `uv` timer polls `result.json` mtime; on change + valid JSON → `teardown()` previous view, `open()` again. Invalid JSON = partial write, retried next tick.
   - `quit()` (guarded by `closed`): stop timer, teardown, `jobstop`, delete terminal buffer, close tab, delete temp dir. Triggered by `q` in panel, `:TrailmapClose`, `TabClosed`, or timer noticing the tab is gone.
6. **`M.setup(opts)`** — `tbl_deep_extend` into config, defines `:Trailmap` and `:TrailmapAgent`.

## Design decisions (don't undo without reason)

- **The agent does all searching and self-review.** Earlier versions ran `codegraph explore` from Lua, parsed its markdown output, and ran 3 headless `claude -p` calls (locate → verify → revise). All removed deliberately; keep the plugin a thin viewer.
- **Interactive session, not headless.** User wants to keep chatting. Communication is one-way via the result file; the prompt tells the agent to overwrite it whenever its answer's locations change.
- **No summary/question header in the panel** — the user asked for it removed; the explanation lives in the agent chat. `summary` is still in the JSON (used only in the "No code found" notification).
- **Claude permissions:** `--allowedTools` pre-approves only `mcp__codegraph__codegraph_explore`, `Bash(codegraph explore:*)`, `Read`, `Grep`, `Glob`, and `Write(/<abs result path>)` (the leading `/` makes `//abs` = absolute path rule). Prompt says to use the write tool, not shell, so it matches the rule. The prompt must be the first positional arg *before* `--allowedTools` (variadic flag would swallow it).
- **Codex:** `--sandbox workspace-write --add-dir <tempdir>`; it can technically write the repo — documented in README Security.
- Command names avoid `:Explore` (netrw owns it).

## Status / open work

- Repo: `git init`ed on `main`, **nothing committed, not pushed**. Planned: `gh repo create pialechini/trailmap.nvim --public --source . --push` (confirm with user first — public).
- The user's nvim config loads it from here: `~/.config/nvim/lua/plugins/trailmap.lua` (`dir = "~/Projects/trailmap.nvim"`, key `<leader>sT`). After publishing, switch that spec to `"pialechini/trailmap.nvim"`.
- Old copy `~/.config/nvim/explore.nvim/` is unused; user hasn't decided to delete it.
- **Untested:** terminal `<C-h/j/k/l>` navigation and `BufEnter → startinsert` in a real UI (headless nvim doesn't keep terminal mode). Codex in interactive mode never run end-to-end.
- Tested: full Claude interactive run (result written, view rendered); fake-agent runs for layout, re-render and `:TrailmapClose`.
- Ideas mentioned but not done: README screenshot, `doc/trailmap.txt` vimdoc, configurable keymaps (`<leader>ee`, terminal nav keys conflict with Claude's `Ctrl+L`/`Ctrl+J`), delete unused `highlight()`.

## Testing

No test suite. Smoke checks used so far:

```sh
# load
nvim --headless -u NONE --cmd 'set rtp+=.' -c 'lua require("trailmap").setup(); print("ok")' -c q

# fake agent: replace jobstart so a shell script writes result.json; run from a repo with that file
cd <some repo> && nvim --headless -u NONE --cmd 'set rtp+=~/Projects/trailmap.nvim' -c 'set columns=200' \
  -c 'lua local m=require("trailmap"); m.setup(); local orig=vim.fn.jobstart; vim.fn.jobstart=function(c,o) return orig({"sh","-c","sleep 1; printf %s \"$0\" > \"$1\"; sleep 30", vim.json.encode({summary="s",files={{file="<repo-relative file>",ranges={{start=1,["end"]=5,why="x"}}}}}), c[4]:match("Write%(/(.-)%)$")}, o) end; m.ask("q"); vim.wait(4000, function() return #vim.api.nvim_tabpage_list_wins(0)>=3 end, 100); print(#vim.api.nvim_tabpage_list_wins(0)); vim.cmd("TrailmapClose")' -c 'qa!'
```

(`c[4]` is the `--allowedTools` value for the claude argv; adjust if argv order changes.) For a real run, drop the `jobstart` override and wait up to a few minutes. Terminal-mode behaviour needs a real UI — no tmux on this machine.

## Conventions

- Lua style matches existing code: 2-space indent, `local function`, short comments only where intent isn't obvious, `---@param`/`---@class` annotations on public bits.
- Keep it one file unless it grows a lot.
- Neovim 0.11+ APIs are fine (`vim.system`, `jobstart{term=true}`, `nvim_open_win` splits, `vim.uv`).
- Default highlight groups use `{ default = true, link = ... }` so users can override.
