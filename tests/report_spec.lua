local Tree = require("neotest.types").Tree
local report = require("neotest-vitest.report")

local real_dir, link_dir, file, file_real

local function pos(type, name, parents, parameterized)
  local id = file
  for _, parent in ipairs(parents) do
    id = id .. "::" .. parent
  end
  if type ~= "file" then
    id = id .. "::" .. name
  end
  return {
    type = type,
    id = id,
    path = file,
    name = name,
    range = { 0, 0, 0, 0 },
    is_parameterized = parameterized,
  }
end

local function build_tree()
  return Tree.from_list({
    pos("file", "a.test.ts", {}),
    {
      pos("namespace", "math", {}),
      { pos("test", "adds", { "math" }) },
      { pos("test", "fails", { "math" }) },
      { pos("test", "each %i works", { "math" }, true) },
      { pos("namespace", "nested", { "math" }), { pos("test", "adds", { "math", "nested" }) } },
    },
    { pos("namespace", "math utils", {}), { pos("test", "adds", { "math utils" }) } },
    { pos("namespace", "dyn %s", {}, true), { pos("test", "runs", { "dyn %s" }) } },
  }, function(p)
    return p.id
  end)
end

local function assertion(ancestors, title, status, messages)
  return {
    ancestorTitles = ancestors,
    title = title,
    fullName = table.concat(ancestors, " ") .. " " .. title,
    status = status,
    failureMessages = messages or {},
  }
end

local function full_report(overrides)
  local assertions = {
    assertion({ "math" }, "adds", "passed"),
    assertion(
      { "math" },
      "fails",
      "failed",
      { "AssertionError: expected 2 to be 3\n at " .. file_real .. ":11:23" }
    ),
    assertion({ "math" }, "each 1 works", "passed"),
    assertion({ "math" }, "each 2 works", "failed", { "boom" }),
    assertion({ "math", "nested" }, "adds", "passed"),
    assertion({ "math utils" }, "adds", "failed", { "outside" }),
    assertion({ "dyn x" }, "runs", "passed"),
    assertion({ "dyn y" }, "runs", "passed"),
  }
  local parsed = {
    success = false,
    testResults = {
      { name = file_real, status = "failed", message = "", assertionResults = assertions },
    },
  }
  return vim.tbl_extend("force", parsed, overrides or {})
end

local function only(ids, results)
  local actual = vim.tbl_keys(results)
  table.sort(actual)
  table.sort(ids)
  assert.are.same(ids, actual)
end

describe("report attribution", function()
  before_each(function()
    real_dir = vim.fs.normalize(
      vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)/")) .. "/vitest-real-" .. math.random(1e9)
    )
    vim.fn.mkdir(real_dir, "p")
    link_dir = real_dir .. "-link"
    vim.uv.fs_symlink(real_dir, link_dir)
    file = link_dir .. "/a.test.ts"
    file_real = real_dir .. "/a.test.ts"
    vim.fn.writefile({ "" }, file_real)
  end)
  after_each(function()
    vim.fn.delete(link_dir)
    vim.fn.delete(real_dir, "rf")
  end)

  it("maps real report paths to symlinked positions and ignores unselected tests", function()
    local tree = build_tree()
    local selected = tree:get_key(file .. "::math::adds")
    local results = report.to_results(full_report(), selected, { code = 1, output = "out" })
    only({ file .. "::math::adds" }, results)
    assert.are.equal("passed", results[file .. "::math::adds"].status)
    assert.are.equal("out", results[file .. "::math::adds"].output)
  end)

  it("keeps an overlapping suite name out of a namespace selection", function()
    local tree = build_tree()
    local results = report.to_results(full_report(), tree:get_key(file .. "::math"), { code = 1 })
    assert.is_nil(results[file .. "::math utils::adds"])
    assert.is_nil(results[file .. "::math utils"])
    assert.are.equal("failed", results[file .. "::math"].status)
    assert.are.equal("passed", results[file .. "::math::nested"].status)
    assert.are.equal("failed", results[file .. "::math::fails"].status)
    assert.are.equal(10, results[file .. "::math::fails"].errors[1].line)
  end)

  it("aggregates parameterised cases on their source position", function()
    local tree = build_tree()
    local results = report.to_results(full_report(), tree, { code = 1 })
    local each = results[file .. "::math::each %i works"]
    assert.are.equal("failed", each.status)
    assert.is_truthy(each.short:find("each 1 works: passed", 1, true))
    assert.is_truthy(each.short:find("each 2 works: failed", 1, true))
    assert.are.equal("each 2 works: boom", each.errors[1].message)
    assert.are.equal("passed", results[file .. "::dyn %s::runs"].status)
    assert.are.equal("passed", results[file .. "::dyn %s"].status)
    assert.are.equal("failed", results[file].status)
  end)

  it("fails a selected test that Vitest did not execute", function()
    local tree = build_tree()
    local parsed = full_report({ success = true })
    parsed.testResults[1].assertionResults = { assertion({ "math" }, "fails", "skipped") }
    local results = report.to_results(parsed, tree:get_key(file .. "::math::adds"), { code = 0 })
    assert.are.equal("failed", results[file .. "::math::adds"].status)
    assert.is_truthy(results[file .. "::math::adds"].short:find("not executed", 1, true))
  end)

  it("keeps a genuinely skipped selected test skipped", function()
    local tree = build_tree()
    local parsed = full_report({ success = true })
    parsed.testResults[1].status = "skipped"
    parsed.testResults[1].assertionResults = { assertion({ "math" }, "adds", "skipped") }
    local results = report.to_results(parsed, tree:get_key(file .. "::math::adds"), { code = 0 })
    assert.are.equal("skipped", results[file .. "::math::adds"].status)
  end)

  it("reports import and collection errors on every selected test", function()
    local tree = build_tree()
    local parsed = {
      success = false,
      testResults = {
        {
          name = file_real,
          status = "failed",
          message = "Cannot find module './x'",
          assertionResults = {},
        },
      },
    }
    local single = report.to_results(parsed, tree:get_key(file .. "::math::adds"), { code = 1 })
    assert.are.equal("failed", single[file .. "::math::adds"].status)
    assert.are.equal("Cannot find module './x'", single[file .. "::math::adds"].errors[1].message)
    local whole = report.to_results(parsed, tree, { code = 1 })
    for _, position in tree:iter() do
      assert.are.equal("failed", whole[position.id].status, position.id)
    end
  end)

  it("fails an unexplained non-zero exit or unsuccessful report", function()
    local tree = build_tree()
    local selected = tree:get_key(file .. "::math::adds")
    local parsed = full_report({ success = true })
    parsed.testResults[1].status = "passed"
    parsed.testResults[1].assertionResults = { assertion({ "math" }, "adds", "passed") }
    local exit = report.to_results(parsed, selected, { code = 1 })[file .. "::math::adds"]
    assert.are.equal("failed", exit.status)
    assert.is_truthy(exit.short:find("exited with code 1", 1, true))
    parsed.success = false
    local flagged = report.to_results(parsed, selected, { code = 0 })[file .. "::math::adds"]
    assert.are.equal("failed", flagged.status)
    assert.is_truthy(flagged.short:find("marked the run unsuccessful", 1, true))
    parsed.success = true
    local killed = report.to_results(parsed, selected, { code = 137 })[file .. "::math::adds"]
    assert.are.equal("failed", killed.status)
    assert.is_truthy(killed.short:find("signal 9", 1, true))
    assert.are.equal(
      "passed",
      report.to_results(parsed, selected, { code = 0 })[file .. "::math::adds"].status
    )
  end)

  it("keeps a passing selection when the exit is explained by another reported failure", function()
    local tree = build_tree()
    local results =
      report.to_results(full_report(), tree:get_key(file .. "::math::nested::adds"), { code = 1 })
    assert.are.equal("passed", results[file .. "::math::nested::adds"].status)
  end)

  it("treats files omitted from a directory run as not included", function()
    local dir_tree = Tree.from_list({
      { type = "dir", id = link_dir, path = link_dir, name = "dir", range = nil },
      vim.list_extend({ pos("file", "a.test.ts", {}) }, { { pos("test", "solo", {}) } }),
    }, function(p)
      return p.id
    end)
    local results = report.to_results({ success = true, testResults = {} }, dir_tree, { code = 0 })
    assert.are.equal("skipped", results[file .. "::solo"].status)
  end)

  it("only attributes reported tests when streaming", function()
    local tree = build_tree()
    local results = report.to_results(full_report(), tree, nil, { partial = true })
    assert.is_nil(results[file .. "::math::nested"])
    assert.are.equal("passed", results[file .. "::math::adds"].status)
  end)

  it("rejects missing, empty, invalid, oversized and unknown reports", function()
    local path = real_dir .. "/report.json"
    local _, missing = report.read(path)
    assert.is_truthy(missing:find("missing", 1, true))
    vim.fn.writefile({}, path)
    local _, empty = report.read(path)
    assert.is_truthy(empty:find("empty", 1, true))
    vim.fn.writefile({ "{ not json" }, path)
    local _, invalid = report.read(path)
    assert.is_truthy(invalid:find("invalid", 1, true))
    vim.fn.writefile({
      vim.json.encode({
        testResults = { { name = "x", assertionResults = { { title = "t" } } } },
      }),
    }, path)
    local _, malformed = report.read(path)
    assert.is_truthy(malformed:find("malformed", 1, true))
    vim.fn.writefile({
      vim.json.encode({
        testResults = { { name = "x", assertionResults = { assertion({}, "t", "exploded") } } },
      }),
    }, path)
    local _, unknown = report.read(path)
    assert.is_truthy(unknown:find("unsupported", 1, true))
    local limit = report.max_report_bytes
    report.max_report_bytes = 4
    local _, oversized = report.read(path)
    report.max_report_bytes = limit
    assert.is_truthy(oversized:find("exceeds", 1, true))
  end)

  it("fails every selected position on an infrastructure failure", function()
    local tree = build_tree()
    local results =
      report.fail_all(tree:get_key(file .. "::math"), "JSON reporter file is missing", "out")
    for _, position in tree:get_key(file .. "::math"):iter() do
      assert.are.equal("failed", results[position.id].status)
    end
    assert.is_nil(results[file])
  end)
end)
