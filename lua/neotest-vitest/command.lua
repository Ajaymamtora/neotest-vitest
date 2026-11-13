-- Command construction for neotest-vitest.
--
-- Commands are argv lists executed directly by libuv; nothing here invokes a
-- shell. Legacy string commands are tokenised with a small quote-aware parser
-- so executable paths containing spaces, Unicode or Windows drive/UNC paths
-- are never split on whitespace.
local M = {}

local uv = vim.uv or vim.loop

local function stat_type(path)
  local stat = path and uv.fs_stat(path)
  return stat and stat.type or nil
end

M.is_windows = vim.fn.has("win32") == 1

---Call `callback(dir)` for the directory of `path` and its ancestors until it
---returns a value. The walk includes the checkout root (the first directory
---containing `.git`, which may be a linked worktree's `.git` file) and never
---inspects a different checkout above it.
---@param path string
---@param callback fun(dir: string): any
---@return any
function M.visit_ancestors(path, callback)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  if vim.fs.abspath then
    path = vim.fs.abspath(path)
  end
  local dir = stat_type(path) == "directory" and path or vim.fs.dirname(path)
  for _ = 1, 256 do
    if not dir or dir == "" then
      return nil
    end
    local value = callback(dir)
    if value ~= nil then
      return value
    end
    if stat_type(dir .. "/.git") then
      return nil
    end
    local parent = vim.fs.dirname(dir)
    if not parent or parent == dir then
      return nil
    end
    dir = parent
  end
end

local function split_words(value)
  -- Argument parsing, never shell evaluation. A backslash only escapes
  -- whitespace or a quote, so Windows drive and UNC paths stay literal.
  local words, word, quote, started = {}, {}, nil, false
  local i = 1
  while i <= #value do
    local char = value:sub(i, i)
    local next_char = value:sub(i + 1, i + 1)
    if
      char == "\\"
      and quote ~= "'"
      and next_char ~= ""
      and (next_char:match("%s") or next_char == '"' or next_char == "'")
    then
      word[#word + 1] = next_char
      started = true
      i = i + 2
    elseif char == quote then
      quote = nil
      i = i + 1
    elseif quote then
      word[#word + 1] = char
      started = true
      i = i + 1
    elseif char == "'" or char == '"' then
      quote = char
      started = true
      i = i + 1
    elseif char:match("%s") then
      if started then
        words[#words + 1] = table.concat(word)
        word, started = {}, false
      end
      i = i + 1
    else
      word[#word + 1] = char
      started = true
      i = i + 1
    end
  end
  if quote then
    return nil, "unclosed quote in vitestCommand"
  end
  if started then
    words[#words + 1] = table.concat(word)
  end
  return words
end

---Normalise a user command into a fresh argv list.
---Accepts an argv list (preferred), the path of an existing executable (which
---may contain spaces) or a legacy shell-like string, which is tokenised
---without invoking a shell.
---@param value string|string[]
---@return string[]|nil argv
---@return string|nil error
function M.argv(value)
  if type(value) == "table" then
    local count = #value
    if count == 0 then
      return nil, "vitestCommand argv is empty"
    end
    for key in pairs(value) do
      if type(key) ~= "number" or key < 1 or key > count or key % 1 ~= 0 then
        return nil, "vitestCommand argv must be a dense list"
      end
    end
    local result = {}
    for i = 1, count do
      local item = value[i]
      if type(item) ~= "string" or item:find("%z") or (i == 1 and item == "") then
        return nil, "vitestCommand argv must contain strings and a non-empty executable"
      end
      result[i] = item
    end
    return result
  end
  if type(value) ~= "string" or vim.trim(value) == "" or value:find("%z") then
    return nil, "vitestCommand must be a non-empty string or argv list"
  end
  if stat_type(value) == "file" then
    return { value }
  end
  local words, err = split_words(value)
  if not words or #words == 0 or words[1] == "" then
    return nil, err or "vitestCommand has no executable"
  end
  return words
end

---Vitest's Node entrypoint in the nearest node_modules inside this checkout.
---@param path string
---@return string|nil
function M.vitest_entry(path)
  return M.visit_ancestors(path, function(dir)
    local entry = dir .. "/node_modules/vitest/vitest.mjs"
    return stat_type(entry) == "file" and entry or nil
  end)
end

---Major version of the Vitest installation that owns `entry`.
---@param entry string|nil
---@return integer|nil
function M.vitest_major(entry)
  if not entry then
    return nil
  end
  local file = io.open(vim.fs.dirname(entry) .. "/package.json", "rb")
  if not file then
    return nil
  end
  local content = file:read(64 * 1024)
  file:close()
  local ok, parsed = pcall(vim.json.decode, content or "")
  local version = ok and type(parsed) == "table" and parsed.version
  return type(version) == "string" and tonumber(version:match("^(%d+)%.")) or nil
end

---The default command for a test path: the checkout-local Vitest.
---Windows cannot spawn package-manager `.cmd` shims through libuv, so run the
---installed JavaScript entrypoint with Node there.
---@param path string
---@return string[]
function M.default_argv(path)
  if M.is_windows then
    local entry = M.vitest_entry(path)
    if entry then
      return { "node", entry }
    end
  end
  local suffixes = M.is_windows and { ".exe", ".cmd", "" } or { "" }
  local binary = M.visit_ancestors(path, function(dir)
    for _, suffix in ipairs(suffixes) do
      local candidate = dir .. "/node_modules/.bin/vitest" .. suffix
      if stat_type(candidate) == "file" then
        return candidate
      end
    end
  end)
  return { binary or "vitest" }
end

---Whether argv contains `--name`, `--name=value` or `--no-name` for any name.
---@param argv string[]
---@param names string[]
---@return boolean
function M.has_option(argv, names)
  for _, arg in ipairs(argv) do
    for _, name in ipairs(names) do
      if arg == name or vim.startswith(arg, name .. "=") or arg == name:gsub("^%-%-", "--no-") then
        return true
      end
    end
  end
  return false
end

M.watch_options = { "-w", "--watch", "--run" }

---Whether the final effective watch setting in argv enables watch mode.
---@param argv string[]
---@return boolean
function M.watches(argv)
  local watching = false
  for i, arg in ipairs(argv) do
    if arg == "-w" or arg == "--watch" or arg == "--watch=true" or (i == 2 and arg == "watch") then
      watching = true
    elseif
      arg == "--watch=false"
      or arg == "--no-watch"
      or arg == "--run"
      or (i == 2 and arg == "run")
    then
      watching = false
    end
  end
  return watching
end
M.file_parallelism_options = { "--fileParallelism", "--file-parallelism" }
M.test_timeout_options = { "--testTimeout", "--test-timeout" }
M.hook_timeout_options = { "--hookTimeout", "--hook-timeout" }

---Build the js-debug launch configuration for an argv list.
---@param command string[] full Vitest argv
---@param entry string|nil Vitest Node entrypoint when this adapter selected the executable
---@return table
function M.dap_config(command, entry)
  local config = {
    name = "Debug Vitest tests",
    type = "pwa-node",
    request = "launch",
    console = "integratedTerminal",
    internalConsoleOptions = "neverOpen",
    autoAttachChildProcesses = true,
    sourceMaps = true,
    smartStep = true,
    skipFiles = { "<node_internals>/**", "**/node_modules/**" },
  }
  local first_arg = 2
  if entry then
    -- Launch Node with Vitest's real entrypoint instead of asking js-debug to
    -- run a symlinked `.bin` wrapper or a Windows `.cmd` shim as the runtime.
    if command[1] == "node" and command[2] == entry then
      first_arg = 3
    end
    config.runtimeExecutable = "node"
    config.program = entry
  else
    -- A caller-selected package-manager command stays exactly as given;
    -- js-debug's bootloader attaches to the Node processes it spawns.
    config.runtimeExecutable = command[1]
  end
  config.args = { unpack(command, first_arg) }
  return config
end

return M
