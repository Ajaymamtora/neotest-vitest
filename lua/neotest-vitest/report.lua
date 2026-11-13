-- Truthful mapping from a Vitest JSON report to Neotest results.
--
-- * Only positions inside the requested selection receive results; tests that
--   Vitest reports outside it (filtered siblings, overlapping suite names,
--   `a.test.tsx` next to `a.test.ts`) never overwrite unrelated state.
-- * Runtime titles of parameterised tests are attributed to their discovered
--   source position and aggregated (any failure fails the position).
-- * A missing, empty, malformed or oversized report, a selected test that was
--   not executed, or an unexplained non-zero exit is an infrastructure failure,
--   never a pass or a silent skip.
local pattern = require("neotest-vitest.pattern")
local util = require("neotest-vitest.util")

local M = {}

local uv = vim.uv or vim.loop

M.max_report_bytes = 64 * 1024 * 1024

local status_map = {
  passed = "passed",
  failed = "failed",
  skipped = "skipped",
  pending = "skipped",
  todo = "skipped",
  disabled = "skipped",
}

local rank = { skipped = 1, passed = 2, failed = 3 }

---Canonical key for comparing paths reported by Vitest (real paths) with
---Neotest's discovered paths (which may traverse symlinks such as macOS /tmp).
---@param path string
---@return string
function M.path_key(path)
  local resolved = uv.fs_realpath(path) or path
  resolved = vim.fs.normalize(resolved)
  if vim.fn.has("win32") == 1 then
    resolved = resolved:lower()
  end
  return resolved
end

---Read and validate a report.
---@param path string|nil
---@return table|nil report
---@return string|nil error
function M.read(path)
  local stat = path and uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil, "JSON reporter file is missing"
  end
  if stat.size == 0 then
    return nil, "JSON reporter file is empty"
  end
  if stat.size > M.max_report_bytes then
    return nil, ("JSON reporter file exceeds %d MiB"):format(M.max_report_bytes / 1024 / 1024)
  end
  local file, open_err = io.open(path, "rb")
  if not file then
    return nil, "cannot read JSON reporter: " .. tostring(open_err)
  end
  local content = file:read("*a")
  file:close()
  return M.decode(content)
end

---Decode and validate report content.
---@param content string|nil
---@return table|nil report
---@return string|nil error
function M.decode(content)
  if type(content) ~= "string" or content == "" then
    return nil, "JSON reporter output is empty"
  end
  local ok, parsed = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  if not ok or type(parsed) ~= "table" or type(parsed.testResults) ~= "table" then
    return nil, "JSON reporter output is invalid"
  end
  for _, file_result in ipairs(parsed.testResults) do
    if
      type(file_result) ~= "table"
      or type(file_result.name) ~= "string"
      or type(file_result.assertionResults or {}) ~= "table"
    then
      return nil, "JSON reporter contains a malformed test file"
    end
    file_result.assertionResults = file_result.assertionResults or {}
    for _, assertion in ipairs(file_result.assertionResults) do
      if
        type(assertion) ~= "table"
        or type(assertion.title) ~= "string"
        or type(assertion.status) ~= "string"
        or type(assertion.ancestorTitles or {}) ~= "table"
        or type(assertion.failureMessages or {}) ~= "table"
      then
        return nil, "JSON reporter contains a malformed assertion"
      end
      if not status_map[assertion.status] then
        return nil, "JSON reporter contains an unsupported assertion status: " .. assertion.status
      end
    end
  end
  return parsed
end

local function file_node_of(tree)
  local data = tree:data()
  if data.type == "file" then
    return tree
  end
  for parent in tree:iter_parents() do
    if parent:data().type == "file" then
      return parent
    end
  end
end

local function find_child(node, title, kinds)
  local fallback
  for _, child in ipairs(node:children()) do
    local data = child:data()
    if kinds[data.type] then
      if data.name == title then
        return child
      end
      if not fallback and data.is_parameterized and pattern.matcher(data.name, true)(title) then
        fallback = child
      end
    end
  end
  return fallback
end

local function resolve(file_node, assertion)
  local node = file_node
  for _, ancestor in ipairs(assertion.ancestorTitles or {}) do
    if ancestor ~= "" then
      node = find_child(node, ancestor, { namespace = true })
      if not node then
        return nil
      end
    end
  end
  return find_child(node, assertion.title, { test = true })
end

local function failure_errors(report_path, assertion)
  local errors = {}
  for _, message in ipairs(assertion.failureMessages or {}) do
    local clean = util.cleanAnsi(message)
    local line, column = util.findErrorPosition(report_path, clean)
    local location = type(assertion.location) == "table" and assertion.location or nil
    errors[#errors + 1] = {
      message = clean,
      line = (line and line - 1) or (location and location.line and location.line - 1) or nil,
      column = (column and column - 1) or (location and location.column) or nil,
    }
  end
  return errors
end

local function add_error(result, message)
  result.errors = result.errors or {}
  result.errors[#result.errors + 1] = { message = message }
  result.short = (result.short and (result.short .. "\n") or "") .. message
end

---Fail every position in the selection with an infrastructure message.
---@param tree neotest.Tree
---@param message string
---@param output string|nil
---@return table<string, neotest.Result>
function M.fail_all(tree, message, output)
  local detail = "Vitest infrastructure failure: " .. message
  local results = {}
  for _, position in tree:iter() do
    results[position.id] = {
      status = "failed",
      short = detail,
      output = output,
      errors = { { message = detail } },
    }
  end
  return results
end

local function describe_exit(code)
  if code == nil then
    return "Vitest exited without an exit code"
  end
  if code > 128 and code < 160 then
    return ("Vitest was terminated by signal %d (exit code %d)"):format(code - 128, code)
  end
  return ("Vitest exited with code %d"):format(code)
end

---Convert a validated report into results for the selected tree.
---@param parsed table validated report
---@param tree neotest.Tree selected position
---@param process { code?: integer, output?: string }|nil
---@param opts? { partial?: boolean } partial: streamed watch-mode report; only attribute reported tests
---@return table<string, neotest.Result>
function M.to_results(parsed, tree, process, opts)
  local partial = opts and opts.partial
  local output = process and process.output or nil
  local selected = {}
  local file_nodes = {}
  for _, node in tree:iter_nodes() do
    local data = node:data()
    selected[data.id] = node
    if data.type == "file" then
      file_nodes[M.path_key(data.path)] = node
    end
  end
  local own_file = file_node_of(tree)
  if own_file then
    file_nodes[M.path_key(own_file:data().path)] = own_file
  end

  local results = {}
  local cases = {}
  local reported_files = {}
  local file_errors = {}
  local failure_anywhere = false

  for _, file_result in ipairs(parsed.testResults) do
    local file_node = file_nodes[M.path_key(file_result.name)]
    local file_failed = file_result.status == "failed"
    if file_failed then
      failure_anywhere = true
    end
    local file_id = file_node and file_node:data().id
    if file_id then
      reported_files[file_id] = true
      local message = type(file_result.message) == "string" and util.cleanAnsi(file_result.message)
        or ""
      if file_failed and message ~= "" then
        file_errors[file_id] = message
        if selected[file_id] then
          results[file_id] = {
            status = "failed",
            short = message,
            output = output,
            errors = { { message = message } },
          }
        end
      end
    end
    for _, assertion in ipairs(file_result.assertionResults) do
      local status = status_map[assertion.status]
      if status == "failed" then
        failure_anywhere = true
      end
      local node = file_node and resolve(file_node, assertion)
      local id = node and node:data().id
      if id and selected[id] then
        cases[id] = cases[id] or {}
        table.insert(
          cases[id],
          { assertion = assertion, status = status, report_path = file_result.name }
        )
      end
    end
  end

  -- Tests: aggregate every reported case attributed to the position.
  for id, list in pairs(cases) do
    local status, lines, errors = "skipped", {}, {}
    for _, case in ipairs(list) do
      if rank[case.status] > rank[status] then
        status = case.status
      end
      lines[#lines + 1] = case.assertion.title .. ": " .. case.status
      for _, err in ipairs(failure_errors(case.report_path, case.assertion)) do
        if #list > 1 then
          err.message = case.assertion.title .. ": " .. err.message
        end
        errors[#errors + 1] = err
        lines[#lines + 1] = err.message
      end
    end
    results[id] = {
      status = status,
      short = table.concat(lines, "\n"),
      output = output,
      errors = #errors > 0 and errors or nil,
    }
  end

  if partial then
    return results
  end

  -- Selected tests which Vitest did not report were not executed.
  for id, node in pairs(selected) do
    if node:data().type == "test" and not results[id] then
      local file = file_node_of(node)
      local file_id = file and file:data().id
      if file_id and file_errors[file_id] then
        local message = file_errors[file_id]
        results[id] = {
          status = "failed",
          short = message,
          output = output,
          errors = { { message = message } },
        }
      elseif file_id and not reported_files[file_id] and tree:data().type == "dir" then
        -- Directory runs: Vitest's include/exclude configuration owns which
        -- files belong to it, so an omitted file was not run, not failed.
        results[id] =
          { status = "skipped", short = "File not included in the Vitest run", output = output }
      else
        local message = "Vitest did not report this test; it was not executed"
        results[id] = {
          status = "failed",
          short = message,
          output = output,
          errors = { { message = message } },
        }
      end
    end
  end

  -- Containers aggregate their own descendants within the selection.
  local function aggregate(node)
    local data = node:data()
    if data.type == "test" then
      return results[data.id].status
    end
    local status = "skipped"
    for _, child in ipairs(node:children()) do
      local child_status = aggregate(child)
      if rank[child_status] > rank[status] then
        status = child_status
      end
    end
    local existing = results[data.id]
    if existing then
      if rank[existing.status] > rank[status] then
        status = existing.status
      end
      existing.status = status
    else
      results[data.id] = { status = status, output = output }
    end
    return status
  end
  aggregate(tree)

  -- Exit status and the reporter's success flag are authoritative. A
  -- non-zero exit is only explained by a failure Vitest itself reported.
  local code = process and process.code
  local bad_exit = code ~= nil and code ~= 0
  local unexplained = (parsed.success == false or bad_exit) and not failure_anywhere
  local abnormal = bad_exit and code ~= 1
  if unexplained or abnormal then
    local reason = bad_exit and describe_exit(code)
      or "Vitest's JSON reporter marked the run unsuccessful"
    local root = results[tree:data().id]
    root.status = "failed"
    add_error(root, "Vitest infrastructure failure: " .. reason)
  end

  return results
end

return M
