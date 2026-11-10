-- trailmap.nvim: ask a question; an AI agent (Claude or Codex) maps the code that answers it.
local M = {}

local ns = vim.api.nvim_create_namespace("trailmap")

---@class TrailmapSnippet
---@field file string
---@field start integer
---@field lines string[]

--- Apply treesitter highlights of `lang` to a snippet occupying rows [row, row+#lines).
local function highlight(buf, row, lines, lang)
  if not lang then
    return
  end
  local text = table.concat(lines, "\n")
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok or not parser then
    return
  end
  local query = vim.treesitter.query.get(lang, "highlights")
  if not query then
    return
  end
  local tree = parser:parse()[1]
  for id, node in query:iter_captures(tree:root(), text, 0, -1) do
    local name = query.captures[id]
    if name:sub(1, 1) ~= "_" and name ~= "spell" and name ~= "nospell" then
      local sr, sc, er, ec = node:range()
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, row + sr, sc, {
        end_row = row + er,
        end_col = ec,
        hl_group = "@" .. name .. "." .. lang,
        priority = 100 + (node:named() and 1 or 0),
      })
    end
  end
end

vim.api.nvim_set_hl(0, "TrailmapRange", { default = true, link = "DiffChange" })
vim.api.nvim_set_hl(0, "TrailmapSign", { default = true, link = "DiffAdd" })
vim.api.nvim_set_hl(0, "TrailmapGuide", { default = true, link = "NonText" })
vim.api.nvim_set_hl(0, "TrailmapLoc", { default = true, link = "DiagnosticWarn" })
vim.api.nvim_set_hl(0, "TrailmapRangeCount", { default = true, link = "Comment" })
vim.api.nvim_set_hl(0, "TrailmapFold", { default = true, link = "NonText" })

local function icon(file)
  local ok, mi = pcall(require, "mini.icons")
  if ok and _G.MiniIcons then
    local i, hl = mi.get("file", file)
    return i, hl
  end
  local ok2, dev = pcall(require, "nvim-web-devicons")
  if ok2 then
    local i, hl = dev.get_icon(file, nil, { default = true })
    return i, hl
  end
  return "", "Normal"
end

local function dir_icon(open_)
  return open_ and "\u{f115}" or "\u{f114}", "Directory"
end

--- Number of distinct lines covered by a file's ranges.
local function loc(ranges)
  local seen, n = {}, 0
  for _, r in ipairs(ranges) do
    for l = r[1], r[2] do
      if not seen[l] then
        seen[l], n = true, n + 1
      end
    end
  end
  return n
end

--- Group snippets by file (first-seen order kept for ranking, tree sorted by path).
local function group(snippets)
  local by, order = {}, {}
  for _, s in ipairs(snippets) do
    if not by[s.file] then
      by[s.file] = {}
      table.insert(order, s.file)
    end
    table.insert(by[s.file], { s.start, s.finish, s.why })
  end
  table.sort(order)
  return by, order
end

--- Highlight ranges in a real file buffer and install ]s/[s there.
local function mark_file(buf, ranges, touched, nav)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local count = vim.api.nvim_buf_line_count(buf)
  for i, r in ipairs(ranges) do
    local s, e = math.min(r[1], count), math.min(r[2], count)
    vim.api.nvim_buf_set_extmark(buf, ns, s - 1, 0, {
      end_row = e - 1,
      line_hl_group = "TrailmapRange",
      sign_text = "▎",
      sign_hl_group = "TrailmapSign",
      virt_text = {
        { string.format(" %d/%d ", i, #ranges), "Search" },
        r[3] and { " " .. r[3] .. " ", "Comment" } or nil,
      },
      virt_text_pos = "right_align",
    })
    for l = s + 1, e do
      vim.api.nvim_buf_set_extmark(buf, ns, l - 1, 0, {
        line_hl_group = "TrailmapRange",
        sign_text = "▎",
        sign_hl_group = "TrailmapSign",
      })
    end
  end
  if touched[buf] then
    return
  end
  touched[buf] = true
  local function jump(dir)
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    local target
    for i = (dir > 0 and 1 or #ranges), (dir > 0 and #ranges or 1), dir do
      local l = ranges[i][1]
      if (dir > 0 and l > cur) or (dir < 0 and l < cur) then
        target = l
        break
      end
    end
    if target then
      vim.api.nvim_win_set_cursor(0, { target, 0 })
      vim.cmd("normal! zt")
    end
  end
  vim.keymap.set("n", "]s", function() jump(1) end, { buffer = buf, desc = "Trailmap: next range" })
  vim.keymap.set("n", "[s", function() jump(-1) end, { buffer = buf, desc = "Trailmap: prev range" })
  vim.keymap.set("n", "<Tab>", function() nav(1) end, { buffer = buf, desc = "Trailmap: next file" })
  vim.keymap.set("n", "<S-Tab>", function() nav(-1) end, { buffer = buf, desc = "Trailmap: prev file" })
  vim.keymap.set("n", "<leader>ee", function() nav(0) end, { buffer = buf, desc = "Trailmap: focus panel" })
end

--- Render the panel + ranges into `main` (a window in the trailmap tab).
--- Returns a teardown that removes the panel and file marks, leaving the tab.
local function open(main, question, snippets, quit)
  local by, files = group(snippets)
  local touched = {}

  -- Build a directory tree; single-child directory chains are compacted ("src/features/reel").
  local root = { name = "", path = "", dirs = {}, files = {} }
  for _, f in ipairs(files) do
    local node, path = root, ""
    local parts = vim.split(f, "/", { plain = true })
    for i = 1, #parts - 1 do
      path = path == "" and parts[i] or (path .. "/" .. parts[i])
      node.dirs[parts[i]] = node.dirs[parts[i]] or { name = parts[i], path = path, dirs = {}, files = {} }
      node = node.dirs[parts[i]]
    end
    table.insert(node.files, f)
  end
  local function compact(node)
    for k, d in pairs(node.dirs) do
      while #d.files == 0 and vim.tbl_count(d.dirs) == 1 do
        local _, only = next(d.dirs)
        only.name = d.name .. "/" .. only.name
        d = only
      end
      node.dirs[k] = d
      compact(d)
    end
  end
  compact(root)

  local collapsed = {}
  local lines, rowfile, rowdir = {}, {}, {}

  local pbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[pbuf].bufhidden = "wipe"
  vim.bo[pbuf].filetype = "trailmap"

  local function render()
    lines, rowfile, rowdir = {}, {}, {}
    local marks = {}
    local function add(text_parts, meta)
      local line, col, row = "", 0, #lines
      for _, p in ipairs(text_parts) do
        line = line .. p[1]
        if p[2] then
          table.insert(marks, { row, col, col + #p[1], p[2] })
        end
        col = col + #p[1]
      end
      table.insert(lines, line)
      if meta.file then rowfile[#lines] = meta.file end
      if meta.dir then rowdir[#lines] = meta.dir end
    end
    -- Diffview-style rows: "<loc> <guides><fold> <icon> name". The left gutter holds
    -- the number of lines this question touches in the file (where diffview puts M/?/D).
    local gw = 1
    for _, f in ipairs(files) do
      gw = math.max(gw, #tostring(loc(by[f])))
    end
    local blank = string.rep(" ", gw + 1)
    local function walk(node, guides)
      local dirs = vim.tbl_values(node.dirs)
      table.sort(dirs, function(x, y) return x.name < y.name end)
      local fs = vim.deepcopy(node.files)
      table.sort(fs)
      for _, d in ipairs(dirs) do
        local open_ = not collapsed[d.path]
        local di, dhl = dir_icon(open_)
        add({
          { blank, nil },
          { guides, "TrailmapGuide" },
          { open_ and "\u{f47c} " or "\u{f460} ", "TrailmapFold" },
          { di .. " ", dhl },
          { d.name, "Directory" },
        }, { dir = d.path })
        if open_ then
          walk(d, guides .. "│ ")
        end
      end
      for _, f in ipairs(fs) do
        local name = f:match("[^/]+$")
        local ic, ichl = icon(name)
        add({
          { string.format("%" .. gw .. "d ", loc(by[f])), "TrailmapLoc" },
          { guides .. "  ", "TrailmapGuide" },
          { ic .. " ", ichl },
          { name, nil },
          { " " .. #by[f], "TrailmapRangeCount" },
        }, { file = f })
      end
    end
    walk(root, "")
    vim.bo[pbuf].modifiable = true
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
    vim.bo[pbuf].modifiable = false
    vim.api.nvim_buf_clear_namespace(pbuf, ns, 0, -1)
    for _, m in ipairs(marks) do
      if m[3] == -1 then
        vim.api.nvim_buf_set_extmark(pbuf, ns, m[1], 0, { line_hl_group = m[4] })
      else
        vim.api.nvim_buf_set_extmark(pbuf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
      end
    end
  end
  render()

  local panel = vim.api.nvim_open_win(pbuf, false, { split = "left", win = main, width = 36 })
  for opt, v in pairs({ number = false, relativenumber = false, signcolumn = "no", wrap = false, cursorline = true, winfixwidth = true, statuscolumn = "" }) do
    vim.wo[panel][opt] = v
  end

  local step
  local function open_file(f, focus)
    if not vim.api.nvim_win_is_valid(main) then
      return
    end
    vim.api.nvim_win_call(main, function()
      vim.cmd("edit " .. vim.fn.fnameescape(f))
    end)
    local buf = vim.api.nvim_win_get_buf(main)
    mark_file(buf, by[f], touched, function(dir)
      if dir == 0 then
        if vim.api.nvim_win_is_valid(panel) then vim.api.nvim_set_current_win(panel) end
        return
      end
      step(dir, true)
    end)
    vim.api.nvim_win_set_cursor(main, { math.min(by[f][1][1], vim.api.nvim_buf_line_count(buf)), 0 })
    vim.api.nvim_win_call(main, function() vim.cmd("normal! zt") end)
    if focus then
      vim.api.nvim_set_current_win(main)
    end
  end

  local function file_at_cursor()
    return rowfile[vim.api.nvim_win_get_cursor(panel)[1]]
  end
  function step(dir, focus)
    local cur = vim.api.nvim_win_get_cursor(panel)[1]
    local r = cur + dir
    while r >= 1 and r <= #lines do
      if rowfile[r] then
        vim.api.nvim_win_set_cursor(panel, { r, 0 })
        open_file(rowfile[r], focus)
        return
      end
      r = r + dir
    end
  end
  local function teardown()
    for b in pairs(touched) do
      if vim.api.nvim_buf_is_valid(b) then
        vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
        pcall(vim.keymap.del, "n", "]s", { buffer = b })
        for _, k in ipairs({ "[s", "<Tab>", "<S-Tab>", "<leader>ee" }) do
          pcall(vim.keymap.del, "n", k, { buffer = b })
        end
      end
    end
    if vim.api.nvim_win_is_valid(panel) then
      vim.api.nvim_win_close(panel, true)
    end
  end

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = pbuf, nowait = true, desc = desc })
  end
  local function activate(focus)
    local row = vim.api.nvim_win_get_cursor(panel)[1]
    if rowfile[row] then
      open_file(rowfile[row], focus)
    elseif rowdir[row] then
      collapsed[rowdir[row]] = not collapsed[rowdir[row]]
      render()
      vim.api.nvim_win_set_cursor(panel, { math.min(row, #lines), 0 })
    end
  end
  local function set_collapsed(val)
    local row = vim.api.nvim_win_get_cursor(panel)[1]
    local d = rowdir[row]
    if not d and rowfile[row] and val then
      -- on a file: collapse the nearest enclosing directory above it
      for r = row - 1, 1, -1 do
        if rowdir[r] and rowfile[row]:find(rowdir[r] .. "/", 1, true) == 1 then
          d = rowdir[r]
          break
        end
      end
    end
    if not d then return end
    collapsed[d] = val
    render()
    for r, p in pairs(rowdir) do
      if p == d then vim.api.nvim_win_set_cursor(panel, { r, 0 }) end
    end
  end
  map("<CR>", function() activate(true) end, "Open file / toggle dir")
  map("o", function() activate(true) end, "Open file / toggle dir")
  map("<2-LeftMouse>", function() activate(true) end, "Open file / toggle dir")
  map("<LeftRelease>", function() activate(false) end, "Preview file / toggle dir")
  map("p", function() activate(false) end, "Preview file")
  map("l", function()
    local row = vim.api.nvim_win_get_cursor(panel)[1]
    if rowdir[row] then set_collapsed(false) else activate(false) end
  end, "Expand / preview")
  map("h", function() set_collapsed(true) end, "Collapse")
  map("<Tab>", function() step(1) end, "Next file")
  map("<S-Tab>", function() step(-1) end, "Prev file")
  -- Moving onto a file (j/k/mouse) previews it, like diffview.
  local last_preview
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = pbuf,
    callback = function()
      local f = rowfile[vim.api.nvim_win_get_cursor(panel)[1]]
      if f and f ~= last_preview then
        last_preview = f
        open_file(f, false)
      end
    end,
  })
  map("gq", function()
    local items = {}
    for _, s in ipairs(snippets) do
      table.insert(items, { filename = s.file, lnum = s.start, end_lnum = s.finish, text = s.why or (s.lines and s.lines[1]) or "" })
    end
    vim.fn.setqflist({}, " ", { title = "Trailmap: " .. question, items = items })
    vim.cmd("copen")
  end, "Ranges to quickfix")
  map("q", quit, "Close trailmap")
  vim.api.nvim_create_user_command("TrailmapFocus", function()
    if vim.api.nvim_win_is_valid(panel) then vim.api.nvim_set_current_win(panel) end
  end, { force = true })

  -- Select first file.
  for r = 1, #lines do
    if rowfile[r] then
      vim.api.nvim_win_set_cursor(panel, { r, 0 })
      open_file(rowfile[r], false)
      break
    end
  end
  return teardown
end


M.config = {
  agent = "claude", -- "claude" | "codex"
  width = 0.12, -- agent terminal width: fraction of the editor (< 1) or columns (>= 1)
  agents = {
    claude = { cmd = "claude", model = "sonnet" },
    codex = { cmd = "codex", model = nil }, -- nil: model from ~/.codex/config.toml
  },
}

local PROMPT = [[You locate the code in this repository that answers the developer's question below.

How to search:
- Start with CodeGraph: the `codegraph_explore` MCP tool if you have it, otherwise run `codegraph explore "<query>"` in the shell. YOU decide the queries: use concrete symbol names, domain words, API paths — not the raw question.
- Follow the flow end to end: UI trigger -> hook -> gateway -> server action -> service -> API call (and types/DTO mapping if relevant).
- If CodeGraph returns irrelevant or empty results 2 times, stop using it and search the files yourself.
- Always read the real file around a range before citing it; line numbers must be exact.

Before answering, review your own answer:
- Does each range really show what its `why` claims? Are the bounds exact and tight?
- Remove anything irrelevant; add any missing step of the flow (trigger, mutation, API call).
- Is the summary correct and supported by the code?

Result rules:
- ONLY files that directly implement the answer. No generic infra, shared UI primitives, or unrelated features.
- TIGHT ranges: one function / type / JSX block each, never a whole file; cover the whole body of what you cite.
- Paths repo-relative. Order files by execution flow.
- `why`: under 10 words. `summary`: 1-3 sentences that directly answer the question.
- Do not modify any repository file.

Output: write the answer as JSON to {{RESULT}} with your file-write tool, not the shell (the editor renders it from there), then give the developer a short explanation in chat. Shape:
{"summary": "...", "files": [{"file": "src/a.ts", "ranges": [{"start": 10, "end": 24, "why": "..."}]}]}
The developer may ask follow-up questions; whenever your answer's code locations change, overwrite {{RESULT}} with the full new answer.

Question: ]]

local notif_id = "trailmap"
local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "trailmap", id = notif_id, replace = notif_id })
end

--- Validate a result against the disk; returns snippets.
local function from_ai(data, cwd)
  local snippets = {}
  for _, f in ipairs(data.files or {}) do
    local path = f.file and f.file:gsub("^%./", "") or ""
    if path:sub(1, #cwd + 1) == cwd .. "/" then
      path = path:sub(#cwd + 2)
    end
    local abs = path:sub(1, 1) == "/" and path or (cwd .. "/" .. path)
    if vim.fn.filereadable(abs) == 1 then
      local count = #vim.fn.readfile(abs)
      for _, r in ipairs(f.ranges or {}) do
        local s, e = tonumber(r.start), tonumber(r["end"])
        if s and e then
          s, e = math.max(1, math.min(s, e)), math.min(count, math.max(s, e))
          if s <= count then
            table.insert(snippets, { file = path, start = s, finish = e, why = r.why })
          end
        end
      end
    end
  end
  return snippets
end

local function decode(text)
  local ok, data = pcall(vim.json.decode, text or "")
  return ok and type(data) == "table" and data or nil
end

--- Interactive agent commands: (prompt, result_file) -> argv.
local agents = {}

function agents.claude(prompt, result)
  local c = M.config.agents.claude
  local tools = "mcp__codegraph__codegraph_explore,Bash(codegraph explore:*),Read,Grep,Glob,Write(/" .. result .. ")"
  local cmd = { c.cmd, prompt, "--allowedTools", tools }
  if c.model then
    vim.list_extend(cmd, { "--model", c.model })
  end
  return cmd
end

function agents.codex(prompt, result)
  local c = M.config.agents.codex
  local cmd = { c.cmd, "--sandbox", "workspace-write", "--add-dir", vim.fs.dirname(result) }
  if c.model then
    vim.list_extend(cmd, { "--model", c.model })
  end
  table.insert(cmd, prompt)
  return cmd
end

---@param question string?
function M.ask(question)
  if not question or question == "" then
    vim.ui.input({ prompt = "Trailmap: " }, function(q)
      if q and q ~= "" then
        M.ask(q)
      end
    end)
    return
  end
  local agent = M.config.agent
  if not agents[agent] then
    return notify("Unknown agent: " .. tostring(agent), vim.log.levels.ERROR)
  end
  local cwd = vim.fn.getcwd()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local result = dir .. "/result.json"
  local prompt = PROMPT:gsub("{{RESULT}}", result) .. question

  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  local main = vim.api.nvim_get_current_win()
  vim.bo[vim.api.nvim_get_current_buf()].bufhidden = "wipe"
  local term = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
    split = "right",
    win = main,
    width = M.config.width < 1 and math.floor(vim.o.columns * M.config.width) or M.config.width,
  })
  vim.wo[term].winfixwidth = true
  local tbuf = vim.api.nvim_win_get_buf(term)
  local job = vim.fn.jobstart(agents[agent](prompt, result), { term = true, cwd = cwd })
  -- Leave the agent without the mouse: <C-h/j/k/l> move to the neighbouring window.
  for _, key in ipairs({ "h", "j", "k", "l" }) do
    vim.keymap.set("t", "<C-" .. key .. ">", "<cmd>wincmd " .. key .. "<cr>", { buffer = tbuf, desc = "Trailmap: leave agent" })
  end
  -- Back in the agent window, type straight into it.
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = tbuf,
    callback = function()
      vim.cmd("startinsert")
    end,
  })
  vim.cmd("startinsert")

  local timer = assert(vim.uv.new_timer())
  local teardown, mtime, closed
  local function quit()
    if closed then
      return
    end
    closed = true
    timer:stop()
    timer:close()
    if teardown then
      teardown()
    end
    pcall(vim.fn.jobstop, job)
    if vim.api.nvim_buf_is_valid(tbuf) then
      vim.api.nvim_buf_delete(tbuf, { force = true })
    end
    if vim.api.nvim_tabpage_is_valid(tab) then
      pcall(vim.cmd, vim.api.nvim_tabpage_get_number(tab) .. "tabclose")
    end
    vim.fn.delete(dir, "rf")
  end

  -- Re-render whenever the agent (re)writes the result file, e.g. after a follow-up question.
  timer:start(500, 500, vim.schedule_wrap(function()
    if not vim.api.nvim_tabpage_is_valid(tab) then
      return quit()
    end
    local stat = vim.uv.fs_stat(result)
    if not stat or stat.mtime.nsec == (mtime and mtime.nsec) and stat.mtime.sec == mtime.sec then
      return
    end
    local data = decode(table.concat(vim.fn.readfile(result), "\n"))
    if not data then
      return -- partial write; retry next tick
    end
    mtime = stat.mtime
    local snippets = from_ai(data, cwd)
    if #snippets == 0 then
      return notify("No code found" .. (data.summary and (": " .. data.summary) or ""), vim.log.levels.WARN)
    end
    if not vim.api.nvim_win_is_valid(main) then
      return
    end
    if teardown then
      teardown()
    end
    teardown = open(main, question, snippets, quit)
  end))

  vim.api.nvim_create_autocmd("TabClosed", {
    callback = function()
      if not vim.api.nvim_tabpage_is_valid(tab) then
        quit()
        return true
      end
    end,
  })
  vim.api.nvim_create_user_command("TrailmapClose", quit, { force = true })
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  vim.api.nvim_create_user_command("Trailmap", function(o)
    M.ask(o.args)
  end, { nargs = "*", desc = "Ask a question; an AI agent maps the code that answers it" })
  vim.api.nvim_create_user_command("TrailmapAgent", function(o)
    if o.args == "" then
      return notify("Agent: " .. M.config.agent)
    end
    M.config.agent = o.args
    notify("Agent: " .. o.args)
  end, {
    nargs = "?",
    complete = function() return vim.tbl_keys(agents) end,
    desc = "Show or set the trailmap agent",
  })
end

return M
