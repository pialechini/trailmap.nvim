# trailmap.nvim

Ask a question about your codebase; an AI agent maps the code that answers it.

`:Trailmap how does checkout create an order?` opens a new tab with an interactive
[Claude Code](https://claude.com/claude-code) or [Codex](https://github.com/openai/codex)
session on the right. The agent searches the repository (using
[CodeGraph](https://github.com/colbymchenry/codegraph) when available), then hands
back the exact line ranges that answer the question. trailmap.nvim renders them as a
file tree on the left and highlights each range in the source, so you can walk the
flow from trigger to API call. Keep chatting with the agent; when its answer changes,
the map updates.

## Requirements

- Neovim 0.11+
- [`claude`](https://claude.com/claude-code) and/or [`codex`](https://github.com/openai/codex) on `$PATH`
- Optional: [`codegraph`](https://github.com/colbymchenry/codegraph) with the repository indexed
  (the agent falls back to plain file search without it)
- Optional: [mini.icons](https://github.com/echasnovski/mini.icons) or
  [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) for file icons

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "pialechini/trailmap.nvim",
  cmd = { "Trailmap", "TrailmapAgent" },
  keys = {
    { "<leader>sT", "<cmd>Trailmap<cr>", desc = "Trailmap: ask about the code" },
  },
  opts = {},
}
```

## Usage

| Command | |
| --- | --- |
| `:Trailmap [question]` | Start a session (prompts for the question when omitted) |
| `:TrailmapAgent [claude\|codex]` | Show or switch the agent for this Neovim session |
| `:TrailmapClose` | Stop the agent and close the tab |
| `:TrailmapFocus` | Jump to the file panel |

**File panel**

| Key | |
| --- | --- |
| `<CR>` / `o` | Open file / toggle directory |
| `p` | Preview file |
| `l` / `h` | Expand / collapse |
| `<Tab>` / `<S-Tab>` | Next / previous file |
| `gq` | Send all ranges to the quickfix list |
| `q` | Close |

**Source window**

| Key | |
| --- | --- |
| `]s` / `[s` | Next / previous range |
| `<Tab>` / `<S-Tab>` | Next / previous file |
| `<leader>ee` | Focus the panel |

**Agent terminal**

| Key | |
| --- | --- |
| `<C-h>` `<C-j>` `<C-k>` `<C-l>` | Move to the neighbouring window |

## Configuration

Defaults:

```lua
require("trailmap").setup({
  agent = "claude", -- "claude" | "codex"
  width = 0.4, -- agent terminal width, as a fraction of the editor
  agents = {
    claude = { cmd = "claude", model = "sonnet" },
    codex = { cmd = "codex", model = nil }, -- nil: model from ~/.codex/config.toml
  },
})
```

Highlight groups (all `default`, override freely): `TrailmapRange`, `TrailmapSign`, `TrailmapGuide`.

## How it works

The agent is told to answer by writing JSON to a temporary file:

```json
{ "summary": "...", "files": [{ "file": "src/a.ts", "ranges": [{ "start": 10, "end": 24, "why": "..." }] }] }
```

trailmap.nvim watches that file, checks every range against the files on disk, and
re-renders whenever the agent rewrites it.

## Security

The agent runs as you, in the current working directory.

- **Claude** is pre-approved only for CodeGraph, `Read`, `Grep`, `Glob`, and writing the
  result file; anything else asks for permission in the terminal.
- **Codex** starts in the `workspace-write` sandbox, so it can edit files in the
  repository. The prompt tells it not to, but review what it does.

## License

[MIT](LICENSE)
