---@diagnostic disable: undefined-field
local async = require("neotest.async")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local util = require("neotest-vitest.util")
local command_util = require("neotest-vitest.command")
local pattern = require("neotest-vitest.pattern")
local report = require("neotest-vitest.report")

---@class neotest.VitestOptions
---@field vitestCommand? string|string[]|fun(path: string): string|string[] argv list, executable path or legacy command string
---@field vitestConfigFile? string|fun(): string
---@field env? table<string, string>|fun(spec_env: table<string, string>): table<string, string>
---@field cwd? string|fun(): string
---@field filter_dir? fun(name: string, relpath: string, root: string): boolean
---@field is_test_file? fun(file_path: string): boolean

---@class neotest.Adapter
local adapter = { name = "neotest-vitest" }

---@param packageJsonContent string
---@return boolean
local function hasVitestDependencyInJson(packageJsonContent)
  local parsedPackageJson = vim.json.decode(packageJsonContent)

  for _, dependencyType in ipairs({ "dependencies", "devDependencies" }) do
    if parsedPackageJson[dependencyType] then
      for key, _ in pairs(parsedPackageJson[dependencyType]) do
        if key == "vitest" or key == "@vitest/ui" or key == "@vitest/coverage-v8" then
          return true
        end
      end
    end
  end

  return false
end

---@return boolean
local function hasRootProjectVitestDependency()
  local rootPackageJson = vim.loop.cwd() .. "/package.json"

  local success, packageJsonContent = pcall(lib.files.read, rootPackageJson)
  if not success then
    print("cannot read package.json, got " .. rootPackageJson)
    return false
  end

  return hasVitestDependencyInJson(packageJsonContent)
end

---@param path string
---@return boolean
local function hasVitestDependency(path)
  local rootPath = lib.files.match_root_pattern("package.json")(path)

  if not rootPath then
    return false
  end

  local success, packageJsonContent = pcall(lib.files.read, rootPath .. "/package.json")
  if not success then
    print("cannot read package.json")
    return false
  end

  local gitRootPath = util.find_git_ancestor(path)
  local hasRootMonorepoVitestDependency = false

  -- only check the git root's package.json if it's different (e.g. in monorepos)
  if gitRootPath and rootPath ~= gitRootPath then
    local monorepoSuccess, monorepoRootPackageJsonContent =
      pcall(lib.files.read, gitRootPath .. "/package.json")
    if monorepoSuccess then
      hasRootMonorepoVitestDependency = hasVitestDependencyInJson(monorepoRootPackageJsonContent)
    end
  end

  return hasVitestDependencyInJson(packageJsonContent)
    or hasRootProjectVitestDependency()
    or hasRootMonorepoVitestDependency
end

adapter.root = function(path)
  return lib.files.match_root_pattern("package.json")(path)
end

function adapter.filter_dir(name, _relpath, _root)
  return name ~= "node_modules"
end

---@param file_path? string
---@return boolean
function adapter.is_test_file(file_path)
  if file_path == nil then
    return false
  end
  local is_test_file = false

  if string.match(file_path, "__tests__") then
    is_test_file = true
  end

  for _, x in ipairs({ "e2e", "spec", "test" }) do
    for _, ext in ipairs({ "js", "jsx", "coffee", "ts", "tsx" }) do
      if string.match(file_path, "%." .. x .. "%." .. ext .. "$") then
        is_test_file = true
        goto matched_pattern
      end
    end
  end
  ::matched_pattern::
  return is_test_file and hasVitestDependency(file_path)
end

local callee_shapes = {
  "(identifier) @func_name",
  "(member_expression object: (identifier) @func_name)",
  "(member_expression object: (member_expression object: (identifier) @func_name))",
}

local function build_query()
  -- `describe("x", fn)`, `describe.skip("x", fn)`, `describe.concurrent.skip("x", fn)`
  -- and their curried forms `describe.each(table)("x", fn)`,
  -- `describe.for(table)("x", fn)`, `describe.skipIf(cond)("x", fn)` and
  -- tagged-template tables. The title may be a string or template literal.
  -- Every shape is a separate pattern: Neotest needs matches in document
  -- order, which alternations inside a pattern do not preserve.
  local query = {}
  for _, entry in ipairs({
    { kind = "namespace", names = '"describe" "suite"', curried = '"describe" "suite" "layer"' },
    { kind = "test", names = '"it" "test"', curried = '"it" "test"' },
  }) do
    for _, title in ipairs({ "string", "template_string" }) do
      for _, fn in ipairs({ "arrow_function", "function_expression" }) do
        local args = ("arguments: (arguments . (%s) @%s.name (%s))"):format(title, entry.kind, fn)
        for _, callee in ipairs(callee_shapes) do
          query[#query + 1] = ("((call_expression function: %s %s) (#any-of? @func_name %s)) @%s.definition"):format(
            callee,
            args,
            entry.names,
            entry.kind
          )
          query[#query + 1] = ("((call_expression function: (call_expression function: %s) %s) (#any-of? @func_name %s)) @%s.definition"):format(
            callee,
            args,
            entry.curried,
            entry.kind
          )
        end
      end
    end
  end
  return table.concat(query, "\n")
end

local discovery_query = build_query()

local escapes = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f", v = "\v", ["0"] = "\0" }

local function utf8_char(code)
  local ok, char = pcall(vim.fn.nr2char, code, 1)
  return ok and char or ""
end

---@param text string source text of a string or template literal title
---@return string
local function unquote(text)
  local body = text:sub(2, -2)
  local out, i = {}, 1
  while i <= #body do
    local char = body:sub(i, i)
    if char ~= "\\" then
      out[#out + 1] = char
      i = i + 1
    else
      local next_char = body:sub(i + 1, i + 1)
      local hex = next_char == "x" and body:match("^%x%x", i + 2)
      local unicode = next_char == "u" and body:match("^%x%x%x%x", i + 2)
      local braced = next_char == "u" and body:match("^{(%x+)}", i + 2)
      if hex then
        out[#out + 1] = utf8_char(tonumber(hex, 16))
        i = i + 4
      elseif braced then
        out[#out + 1] = utf8_char(tonumber(braced, 16))
        i = i + 4 + #braced
      elseif unicode then
        out[#out + 1] = utf8_char(tonumber(unicode, 16))
        i = i + 6
      elseif next_char == "\n" then
        -- Line continuation.
        i = i + 2
      else
        out[#out + 1] = escapes[next_char] or next_char
        i = i + 2
      end
    end
  end
  return table.concat(out)
end

--- Build Neotest positions for discovery. Referenced by name so that it also
--- works when Neotest parses files in a subprocess.
function adapter._build_position(file_path, source, captured_nodes)
  local kind = captured_nodes["test.name"] and "test"
    or captured_nodes["namespace.name"] and "namespace"
  if not kind then
    return nil
  end
  local name_node = captured_nodes[kind .. ".name"]
  local definition = captured_nodes[kind .. ".definition"]
  local parameterized = false
  local callee = definition:field("function")[1]
  if callee and callee:type() == "call_expression" then
    local inner = callee:field("function")[1]
    if inner and inner:type() == "member_expression" then
      local property = inner:field("property")[1]
      local property_name = property and vim.treesitter.get_node_text(property, source)
      parameterized = property_name == "each" or property_name == "for"
    end
  end
  if name_node:type() == "template_string" then
    for child in name_node:iter_children() do
      if child:type() == "template_substitution" then
        -- Runtime text is unknown; every substitution is a wildcard.
        parameterized = true
      end
    end
  end
  return {
    type = kind,
    path = file_path,
    name = unquote(vim.treesitter.get_node_text(name_node, source)),
    range = { definition:range() },
    is_parameterized = parameterized,
  }
end

---@async
---@return neotest.Tree | nil
function adapter.discover_positions(path)
  return lib.treesitter.parse_positions(path, discovery_query, {
    nested_tests = true,
    build_position = 'require("neotest-vitest")._build_position',
  })
end

local default_command = nil

---@param path string
---@param override? string|string[]
---@return string[] argv
---@return boolean owned whether this adapter chose the executable
local function resolve_command(path, override)
  local value = override
  if value == nil and default_command then
    value = default_command(path)
  end
  if value == nil then
    return command_util.default_argv(path), true
  end
  local argv, err = command_util.argv(value)
  if not argv then
    error("neotest-vitest: " .. err, 0)
  end
  return argv, false
end

-- Ordered by config precedence (https://vitest.dev/config/#configuration)
local configNames = {
  "vitest.config.ts",
  "vitest.config.mts",
  "vitest.config.cts",
  "vitest.config.js",
  "vitest.config.mjs",
  "vitest.config.cjs",
  "vite.config.ts",
  "vite.config.mts",
  "vite.config.cts",
  "vite.config.js",
  "vite.config.mjs",
  "vite.config.cjs",
}

---Nearest Vitest/Vite config inside the test's checkout.
---@param path string
---@return string|nil
local function getVitestConfig(path)
  return command_util.visit_ancestors(path, function(dir)
    for _, name in ipairs(configNames) do
      local candidate = dir .. "/" .. name
      if util.path.is_file(candidate) then
        return candidate
      end
    end
  end)
end

local function getEnv(specEnv)
  return specEnv
end

---@param path string
---@return string|nil
local function getCwd(path)
  local config = getVitestConfig(path)
  if config then
    return vim.fs.dirname(config)
  end
  return command_util.visit_ancestors(path, function(dir)
    return util.path.is_dir(dir .. "/node_modules") and dir or nil
  end)
end

---Names from the outermost namespace down to the selected position.
local function selection_names(tree)
  local names = {}
  local node = tree
  while node and node:data().type ~= "file" and node:data().type ~= "dir" do
    local data = node:data()
    table.insert(names, 1, { name = data.name, parameterized = data.is_parameterized })
    node = node:parent()
  end
  return names
end

---Path filter passed to Vitest. Vitest compares filters with real paths and
---treats them as substrings, so resolve symlinks (e.g. macOS /tmp) and keep a
---trailing separator on directories so `src` cannot select `src2`.
local function path_filter(position)
  local resolved =
    vim.fs.normalize((vim.uv or vim.loop).fs_realpath(position.path) or position.path)
  if position.type == "dir" and not resolved:match("/$") then
    resolved = resolved .. "/"
  end
  return resolved
end

---@param args neotest.RunArgs
---@return neotest.RunSpec | nil
function adapter.build_spec(args)
  local tree = args.tree
  if not tree then
    return
  end
  local pos = tree:data()

  local command, owned = resolve_command(pos.path, args.vitestCommand)
  local entry = command_util.vitest_entry(pos.path)
  local major = entry and command_util.vitest_major(entry) or nil
  if not owned and not (command[1] == "node" and command[2] == entry) then
    -- A caller-supplied command may run a different installation; only trust
    -- the local version when it is the one being executed.
    major = nil
  end

  local config = getVitestConfig(pos.path)
  if config and util.path.exists(config) then
    -- only use config if available
    table.insert(command, "--config=" .. config)
  end

  local results_path = async.fn.tempname() .. ".json"
  vim.list_extend(command, {
    "--reporter=verbose",
    "--reporter=json",
    "--outputFile=" .. results_path,
  })
  local testNamePattern = pattern.build(selection_names(tree), pos.type, major) or ".*"
  table.insert(command, "--testNamePattern=" .. testNamePattern)
  local selected_path = path_filter(pos)
  table.insert(command, selected_path)
  if pos.type ~= "dir" then
    -- CLI file filters are substrings, not exact filenames. Without this
    -- exclusion, selecting foo.test.ts also executes foo.test.tsx.
    -- Vitest 1 matches exclusions against relative paths; later releases also
    -- match absolute paths. A basename glob works with either root convention.
    local literal_name = vim.fn.fnamemodify(selected_path, ":t"):gsub("([*?%[%]{}()!+@])", "\\%1")
    table.insert(command, "--exclude=**/" .. literal_name .. "?*")
  end

  vim.list_extend(command, args.extra_args or {})

  if not command_util.has_option(command, command_util.watch_options) then
    table.insert(command, "--watch=false")
  end

  if args.strategy == "dap" then
    -- One debuggee at a time keeps breakpoints and stepping deterministic,
    -- and a paused breakpoint must not trip Vitest's per-test/hook timeouts.
    -- Explicit caller options always win.
    if not command_util.has_option(command, command_util.file_parallelism_options) then
      table.insert(command, "--no-file-parallelism")
    end
    if not command_util.has_option(command, command_util.test_timeout_options) then
      table.insert(command, "--test-timeout=0")
    end
    if not command_util.has_option(command, command_util.hook_timeout_options) then
      table.insert(command, "--hook-timeout=0")
    end
  end

  local cwd = getCwd(pos.path)

  local context = { results_path = results_path, file = pos.path, debug = args.strategy == "dap" }
  local stream
  if command_util.watches(command) then
    -- Watch mode never exits; Vitest rewrites the JSON report after every
    -- run, so stream each complete report. Single runs are read once in
    -- `results` and need no file watcher.
    lib.files.write(results_path, "")
    local stream_data, stop_stream = util.stream(results_path)
    context.stop_stream = stop_stream
    stream = function()
      return function()
        local data = stream_data()
        local ok, parsed = pcall(report.decode, data)
        if not ok or not parsed then
          return {}
        end
        return report.to_results(parsed, tree, nil, { partial = true })
      end
    end
  end

  return {
    command = command,
    cwd = cwd,
    context = context,
    stream = stream,
    -- Neotest fills `env` and `cwd` from the spec (including run arguments).
    strategy = args.strategy == "dap" and command_util.dap_config(command, owned and entry or nil)
      or nil,
    env = getEnv(args[2] and args[2].env or {}),
  }
end

-- Vitest prints this banner (v1+) when unhandled errors fail a run whose
-- tests all passed; the JSON report's `success` flag does not include them.
local UNHANDLED_BANNER = "Vitest caught %d+ unhandled error"

---Neotest's DAP strategy returns exit code 1 whenever the debug adapter
---sends no `exited` event, which js-debug does not for launched Node
---programs. That code carries no information about the debuggee, so for
---debug runs derive a failing exit only from Vitest's own output.
---@async
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult|nil
---@return { code?: integer, output?: string }|nil
local function debug_process(spec, result)
  if not (spec.context and spec.context.debug and result and result.code == 1) then
    return result
  end
  local ok, output = pcall(lib.files.read, result.output)
  local unhandled = ok and type(output) == "string" and output:find(UNHANDLED_BANNER) ~= nil
  return { output = result.output, code = unhandled and 1 or nil }
end

---@async
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
function adapter.results(spec, result, tree)
  local results_path = spec.context and spec.context.results_path
  if spec.context and spec.context.stop_stream then
    spec.context.stop_stream()
  end
  local parsed, err = report.read(results_path)
  if results_path then
    -- Report filenames are never reused; remove the consumed report so a
    -- long session does not accumulate them.
    pcall(os.remove, results_path)
  end
  if not parsed then
    local code = result and result.code
    if type(code) == "number" and code ~= 0 then
      err = ("%s (Vitest exited with code %d)"):format(err, code)
    end
    logger.error("neotest-vitest:", err, results_path)
    return report.fail_all(tree, err, result and result.output)
  end
  return report.to_results(parsed, tree, debug_process(spec, result))
end

local defaults = {
  config = getVitestConfig,
  env = getEnv,
  cwd = getCwd,
  filter_dir = adapter.filter_dir,
  is_test_file = adapter.is_test_file,
}

local is_callable = function(obj)
  return type(obj) == "function" or (type(obj) == "table" and obj.__call)
end

setmetatable(adapter, {
  ---@param opts neotest.VitestOptions
  __call = function(_, opts)
    opts = opts or {}
    -- The adapter is a module singleton: each configuration replaces the
    -- previous one instead of inheriting options from an earlier setup.
    default_command = nil
    getVitestConfig, getEnv, getCwd = defaults.config, defaults.env, defaults.cwd
    adapter.filter_dir, adapter.is_test_file = defaults.filter_dir, defaults.is_test_file

    -- A string (legacy), an argv list or a function of the test path
    -- returning either. Strings are tokenised without invoking a shell.
    if is_callable(opts.vitestCommand) then
      default_command = opts.vitestCommand
    elseif opts.vitestCommand then
      default_command = function()
        return vim.deepcopy(opts.vitestCommand)
      end
    end

    if is_callable(opts.vitestConfigFile) then
      getVitestConfig = opts.vitestConfigFile
    elseif opts.vitestConfigFile then
      getVitestConfig = function()
        return opts.vitestConfigFile
      end
    end

    if is_callable(opts.env) then
      getEnv = opts.env
    elseif opts.env then
      getEnv = function(specEnv)
        return vim.tbl_extend("force", opts.env, specEnv)
      end
    end

    if is_callable(opts.cwd) then
      getCwd = opts.cwd
    elseif opts.cwd then
      getCwd = function()
        return opts.cwd
      end
    end

    if is_callable(opts.filter_dir) then
      adapter.filter_dir = opts.filter_dir
    end

    if is_callable(opts.is_test_file) then
      adapter.is_test_file = function(file_path)
        return hasVitestDependency(file_path) and opts.is_test_file(file_path)
      end
    end

    return adapter
  end,
})

return adapter
