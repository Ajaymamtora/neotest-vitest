local async = require("nio").tests
local Tree = require("neotest.types").Tree

---@type neotest.Adapter
local plugin = require("neotest-vitest")({
  vitestCommand = "vitest",
})
require("neotest-vitest-assertions")
A = function(...)
  print(vim.inspect(...))
end

describe("adapter enabled", function()
  async.it("vitest simple repo", function()
    assert.Not.Nil(plugin.root("./spec"))
  end)

  async.it("disable adapter no package.json", function()
    assert.Nil(plugin.root("."))
  end)

  async.it("enable adapter for monorepo with vitest at root", function()
    assert.Not.Nil(plugin.root("./spec-monorepo"))
  end)
end)

describe("is_test_file", function()
  local original_dir
  before_each(function()
    original_dir = vim.api.nvim_eval("getcwd()")
  end)

  after_each(function()
    vim.api.nvim_set_current_dir(original_dir)
  end)

  async.it("matches vitest files", function()
    vim.api.nvim_set_current_dir("./spec")
    assert.is.truthy(plugin.is_test_file("./spec/basic.test.ts"))
  end)

  async.it("does not match plain js files", function()
    assert.is.falsy(plugin.is_test_file("./index.ts"))
  end)

  async.it("does not match file name ending with test", function()
    assert.is.falsy(plugin.is_test_file("./setupVitest.ts"))
  end)

  async.it("does not match test in repo with jest", function()
    vim.api.nvim_set_current_dir("./spec-jest")
    assert.is.falsy(plugin.is_test_file("./spec-jest/basic.test.ts"))
  end)

  async.it("matches vitest files in monorepo", function()
    vim.api.nvim_set_current_dir("./spec-monorepo")
    assert.is.truthy(plugin.is_test_file("./spec-monorepo/packages/example/basic.test.ts"))
    assert.is.truthy(plugin.is_test_file("./spec-monorepo/apps/todo/todo.test.tsx"))
  end)
end)

describe("discover_positions", function()
  local function discover_positions(file_path)
    local positions = plugin.discover_positions(file_path):to_list()
    local function remove_range(obj)
      local islist = vim.islist or vim.tbl_islist
      if islist(obj) then
        vim.tbl_map(remove_range, obj)
      else
        obj["range"] = nil
      end
    end
    remove_range(positions)
    return positions
  end
  async.it("provides meaningful names from a basic spec", function()
    local positions = discover_positions("./spec/basic.test.ts")
    local expected_output = {
      {
        id = "./spec/basic.test.ts",
        name = "basic.test.ts",
        path = "./spec/basic.test.ts",
        type = "file",
      },
      {
        {
          id = "./spec/basic.test.ts::describe arrow function",
          name = "describe arrow function",
          path = "./spec/basic.test.ts",
          type = "namespace",
          is_parameterized = false,
        },
        {
          {
            id = "./spec/basic.test.ts::describe arrow function::foo",
            name = "foo",
            path = "./spec/basic.test.ts",
            type = "test",
            is_parameterized = false,
          },
        },
        {
          {
            id = "./spec/basic.test.ts::describe arrow function::bar(error)",
            name = "bar(error)",
            path = "./spec/basic.test.ts",
            type = "test",
            is_parameterized = false,
          },
        },
      },
      {
        {
          id = "./spec/basic.test.ts::describe vanilla function",
          name = "describe vanilla function",
          path = "./spec/basic.test.ts",
          type = "namespace",
          is_parameterized = false,
        },
        {
          {
            id = "./spec/basic.test.ts::describe vanilla function::foo",
            name = "foo",
            path = "./spec/basic.test.ts",
            type = "test",
            is_parameterized = false,
          },
        },
        {
          {
            id = "./spec/basic.test.ts::describe vanilla function::bar",
            name = "bar",
            path = "./spec/basic.test.ts",
            type = "test",
            is_parameterized = false,
          },
        },
      },
    }
    assert.is.same(expected_output, positions)
  end)

  async.it("provides meaningful names for array driven tests", function()
    local positions = discover_positions("./spec/array.test.ts")
    local expected_output = {
      {
        id = "./spec/array.test.ts",
        name = "array.test.ts",
        path = "./spec/array.test.ts",
        type = "file",
      },
      {
        {
          id = "./spec/array.test.ts::describe text",
          name = "describe text",
          path = "./spec/array.test.ts",
          type = "namespace",
          is_parameterized = false,
        },
        {
          {
            id = "./spec/array.test.ts::describe text::Array1",
            name = "Array1",
            path = "./spec/array.test.ts",
            type = "test",
            is_parameterized = true,
          },
        },
        {
          {
            id = "./spec/array.test.ts::describe text::Array2",
            name = "Array2",
            path = "./spec/array.test.ts",
            type = "test",
            is_parameterized = true,
          },
        },
        {
          {
            id = "./spec/array.test.ts::describe text::Array3",
            name = "Array3",
            path = "./spec/array.test.ts",
            type = "test",
            is_parameterized = true,
          },
        },
        {
          {
            id = "./spec/array.test.ts::describe text::Array4",
            name = "Array4",
            path = "./spec/array.test.ts",
            type = "test",
            is_parameterized = true,
          },
        },
      },
    }
    assert.is.same(expected_output, positions)
  end)
end)

local function real(path)
  return vim.fs.normalize(vim.uv.fs_realpath(path))
end

describe("build_spec", function()
  local raw_tempname
  before_each(function()
    raw_tempname = require("neotest.async").fn.tempname
    require("neotest.async").fn.tempname = function()
      return "/tmp/foo"
    end
  end)
  after_each(function()
    require("neotest.async").fn.tempname = raw_tempname
  end)

  describe("test name pattern", function()
    async.it("file level", function()
      local positions = plugin.discover_positions("./spec/nested.test.ts"):to_list()
      local tree = Tree.from_list(positions, function(pos)
        return pos.id
      end)
      local spec = plugin.build_spec({ tree = tree })
      local command = spec.command
      assert.contains(spec.command, "--testNamePattern=.*")
    end)
    async.it("first level", function()
      local positions = plugin.discover_positions("./spec/nested.test.ts"):to_list()
      local tree = Tree.from_list(positions, function(pos)
        return pos.id
      end)
      local spec = plugin.build_spec({ tree = tree:children()[1] })
      assert.contains(spec.command, "--testNamePattern=^\\s?first\\slevel\\s(?:>\\s)?")
    end)
    async.it("second level", function()
      local positions = plugin.discover_positions("./spec/nested.test.ts"):to_list()
      local tree = Tree.from_list(positions, function(pos)
        return pos.id
      end)
      local spec = plugin.build_spec({ tree = tree:children()[1]:children()[1] })
      assert.contains(
        spec.command,
        "--testNamePattern=^\\s?first\\slevel\\s(?:>\\s)?second\\slevel\\s(?:>\\s)?"
      )
    end)
    async.it("test level", function()
      local positions = plugin.discover_positions("./spec/nested.test.ts"):to_list()
      local tree = Tree.from_list(positions, function(pos)
        return pos.id
      end)
      local spec = plugin.build_spec({ tree = tree:children()[1]:children()[1]:children()[1] })
      assert.contains(
        spec.command,
        "--testNamePattern=^\\s?first\\slevel\\s(?:>\\s)?second\\slevel\\s(?:>\\s)?foo$"
      )
    end)

    async.it("escapes names without treating their spaces as suite boundaries", function()
      local positions = plugin.discover_positions("./spec/separators.test.ts"):to_list()
      local tree = Tree.from_list(positions, function(pos)
        return pos.id
      end)
      local spec = plugin.build_spec({ tree = tree:children()[1]:children()[1]:children()[1] })
      assert.contains(
        spec.command,
        "--testNamePattern=^\\s?outer\\s>\\ssuite\\s(?:>\\s)?inner\\s\\(suite\\)\\s(?:>\\s)?adds\\s1\\s\\+\\s2$"
      )
    end)
    async.it("test level 2", function()
      local positions = plugin.discover_positions("./spec/nested.test.ts"):to_list()
      local tree = Tree.from_list(positions, function(pos)
        return pos.id
      end)
      local spec = plugin.build_spec({ tree = tree:children()[1]:children()[1]:children()[2] })
      assert.contains(
        spec.command,
        "--testNamePattern=^\\s?first\\slevel\\s(?:>\\s)?second\\slevel\\s(?:>\\s)?bar\\(error\\)$"
      )
    end)
  end)

  async.it("builds command for file test", function()
    local positions = plugin.discover_positions("./spec/basic.test.ts"):to_list()
    local tree = Tree.from_list(positions, function(pos)
      return pos.id
    end)
    local spec = plugin.build_spec({ tree = tree })
    assert.is.truthy(spec)
    local expected_command = {
      "vitest",
      "--config=" .. vim.fs.abspath("./spec/vite.config.ts"),
      "--reporter=verbose",
      "--reporter=json",
      "--outputFile=/tmp/foo.json",
      "--testNamePattern=.*",
      real("spec/basic.test.ts"),
      "--watch=false",
    }
    assert.is.same(expected_command, spec.command)
    assert.is.truthy(spec.context.file)
    assert.is.truthy(spec.context.results_path)
  end)

  async.it("builds command passed vitest command ", function()
    local positions = plugin.discover_positions("./spec/basic.test.ts"):to_list()
    local tree = Tree.from_list(positions, function(pos)
      return pos.id
    end)
    local spec = plugin.build_spec({ vitestCommand = "vitest --watch", tree = tree })

    assert.is.truthy(spec)
    local expected_command = {
      "vitest",
      "--watch",
      "--config=" .. vim.fs.abspath("./spec/vite.config.ts"),
      "--reporter=verbose",
      "--reporter=json",
      "--outputFile=/tmp/foo.json",
      "--testNamePattern=.*",
      real("spec/basic.test.ts"),
    }
    assert.is.same(expected_command, spec.command)
    assert.is.falsy(vim.list_contains(spec.command, "--watch=false"))
    assert.is.truthy(spec.context.file)
    assert.is.truthy(spec.context.results_path)
  end)

  async.it("builds command passed watch flag via extra_args", function()
    local positions = plugin.discover_positions("./spec/basic.test.ts"):to_list()
    local tree = Tree.from_list(positions, function(pos)
      return pos.id
    end)
    local spec = plugin.build_spec({ tree = tree, extra_args = { "--watch" } })

    assert.is.truthy(spec)
    assert.is.falsy(vim.list_contains(spec.command, "--watch=false"))
    assert.is.truthy(vim.list_contains(spec.command, "--watch"))
  end)

  async.it("builds command for namespace", function()
    local positions = plugin.discover_positions("./spec/basic.test.ts"):to_list()

    local tree = Tree.from_list(positions, function(pos)
      return pos.id
    end)

    local spec = plugin.build_spec({ tree = tree:children()[1] })

    assert.is.truthy(spec)
    local expected_command = {
      "vitest",
      "--config=" .. vim.fs.abspath("./spec/vite.config.ts"),
      "--reporter=verbose",
      "--reporter=json",
      "--outputFile=/tmp/foo.json",
      "--testNamePattern=^\\s?describe\\sarrow\\sfunction\\s(?:>\\s)?",
      real("spec/basic.test.ts"),
      "--watch=false",
    }
    assert.is.same(expected_command, spec.command)
    assert.is.truthy(spec.context.file)
    assert.is.truthy(spec.context.results_path)
  end)

  async.it("uses vite config", function()
    local positions = plugin.discover_positions("./spec/config/vite/basic.test.ts"):to_list()

    local tree = Tree.from_list(positions, function(pos)
      return pos.id
    end)

    local spec = plugin.build_spec({ tree = tree:children()[1] })

    assert.is.truthy(spec)
    local expected_command = {
      "vitest",
      "--config=" .. vim.fs.abspath("./spec/config/vite/vite.config.ts"),
      "--reporter=verbose",
      "--reporter=json",
      "--outputFile=/tmp/foo.json",
      "--testNamePattern=^\\s?1$",
      real("spec/config/vite/basic.test.ts"),
      "--watch=false",
    }
    assert.is.same(expected_command, spec.command)
    assert.is.truthy(spec.context.file)
    assert.is.truthy(spec.context.results_path)
  end)

  async.it("uses vitest config over vite config", function()
    local positions = plugin.discover_positions("./spec/config/vitest/basic.test.ts"):to_list()

    local tree = Tree.from_list(positions, function(pos)
      return pos.id
    end)

    local spec = plugin.build_spec({ tree = tree:children()[1] })

    assert.is.truthy(spec)
    local expected_command = {
      "vitest",
      "--config=" .. vim.fs.abspath("./spec/config/vitest/vitest.config.ts"),
      "--reporter=verbose",
      "--reporter=json",
      "--outputFile=/tmp/foo.json",
      "--testNamePattern=^\\s?1$",
      real("spec/config/vitest/basic.test.ts"),
      "--watch=false",
    }
    assert.is.same(expected_command, spec.command)
    assert.is.truthy(spec.context.file)
    assert.is.truthy(spec.context.results_path)
  end)
end)

describe("parameterised discovery", function()
  async.it("marks runtime-titled positions and decodes literal titles", function()
    local tree = plugin.discover_positions("./spec/parameterized.test.ts")
    local found = {}
    for _, position in tree:iter() do
      if position.type ~= "file" then
        found[position.id:gsub("^%./spec/parameterized%.test%.ts::", "")] =
          position.is_parameterized
      end
    end
    assert.are.same({
      ["letter %s"] = true,
      ["letter %s::has length one"] = false,
      ["number %i"] = true,
      ["object $a"] = true,
      ["table $a + $b"] = true,
      ["loop ${n}"] = true,
      ["plain template"] = false,
      ["chained"] = false,
      ["chained::curried skipIf"] = false,
      ["chained::it's éscaped"] = false,
    }, found)
  end)
end)

describe("build_spec runtime", function()
  local root
  local function write(path, content)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile({ content or "" }, path)
  end
  before_each(function()
    root = vim.fs.normalize(
      vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)/"))
        .. "/vitest root ü "
        .. math.random(1e9)
    )
    write(root .. "/.git/HEAD", "ref: refs/heads/main")
    write(root .. "/node_modules/.bin/vitest", "#!/bin/sh")
    write(root .. "/node_modules/vitest/vitest.mjs", "")
    write(root .. "/node_modules/vitest/package.json", '{"version":"5.1.0"}')
    write(root .. "/vitest.config.ts", "export default {}")
    vim.fn.mkdir(root .. "/src", "p")
    vim.uv.fs_copyfile("./spec/nested.test.ts", root .. "/src/nested.test.ts")
  end)
  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  local function tree_for(path)
    local positions = plugin.discover_positions(path):to_list()
    return Tree.from_list(positions, function(pos)
      return pos.id
    end)
  end

  async.it("uses the checkout-local runner, its version syntax and real paths", function()
    local adapter = require("neotest-vitest")({})
    local tree = tree_for(root .. "/src/nested.test.ts")
    local test = tree:children()[1]:children()[1]:children()[1]
    local spec = adapter.build_spec({ tree = test })
    if vim.fn.has("win32") == 1 then
      assert.are.same(
        { "node", root .. "/node_modules/vitest/vitest.mjs" },
        { spec.command[1], spec.command[2] }
      )
    else
      assert.are.equal(root .. "/node_modules/.bin/vitest", spec.command[1])
    end
    assert.contains(spec.command, "--config=" .. root .. "/vitest.config.ts")
    assert.contains(
      spec.command,
      "--testNamePattern=^first\\slevel\\s>\\ssecond\\slevel\\s>\\sfoo$"
    )
    assert.contains(spec.command, root .. "/src/nested.test.ts")
    assert.are.equal(root, spec.cwd)
    assert.is_nil(spec.strategy)
    assert.is_nil(spec.stream)
  end)

  async.it("selects a directory without matching sibling prefixes", function()
    local adapter = require("neotest-vitest")({})
    local dir = Tree.from_list(
      { { type = "dir", id = root .. "/src", path = root .. "/src", name = "src" } },
      function(pos)
        return pos.id
      end
    )
    local spec = adapter.build_spec({ tree = dir })
    assert.contains(spec.command, root .. "/src/")
  end)

  async.it("debugs one file at a time without default timeouts", function()
    local adapter = require("neotest-vitest")({})
    local tree = tree_for(root .. "/src/nested.test.ts")
    local spec = adapter.build_spec({ tree = tree, strategy = "dap" })
    for _, flag in ipairs({ "--no-file-parallelism", "--test-timeout=0", "--hook-timeout=0" }) do
      assert.contains(spec.command, flag)
      assert.contains(spec.strategy.args, flag)
    end
    assert.are.equal("node", spec.strategy.runtimeExecutable)
    assert.are.equal(root .. "/node_modules/vitest/vitest.mjs", spec.strategy.program)
    assert.is_true(spec.strategy.autoAttachChildProcesses)

    local explicit = adapter.build_spec({
      tree = tree,
      strategy = "dap",
      extra_args = { "--testTimeout", "30000", "--fileParallelism", "--hook-timeout=5" },
    })
    assert.is_false(vim.list_contains(explicit.command, "--test-timeout=0"))
    assert.is_false(vim.list_contains(explicit.command, "--no-file-parallelism"))
    assert.is_false(vim.list_contains(explicit.command, "--hook-timeout=0"))
    assert.contains(explicit.command, "30000")
  end)

  async.it("never splits caller argv and keeps explicit watch flags", function()
    local adapter = require("neotest-vitest")({})
    local tree = tree_for(root .. "/src/nested.test.ts")
    local custom = { "pnpm", "exec", "vitest", "--watch" }
    local spec = adapter.build_spec({ tree = tree, vitestCommand = custom })
    assert.are.same({ "pnpm", "exec", "vitest", "--watch" }, { unpack(spec.command, 1, 4) })
    assert.are.same({ "pnpm", "exec", "vitest", "--watch" }, custom)
    assert.is_false(vim.list_contains(spec.command, "--watch=false"))
    assert.is_function(spec.stream)
    spec.context.stop_stream()
    -- The caller's runner may be a different installation: use the
    -- version-agnostic name syntax.
    assert.contains(spec.command, "--testNamePattern=.*")
    local debug =
      adapter.build_spec({ tree = tree, vitestCommand = "pnpm exec vitest", strategy = "dap" })
    assert.are.equal("pnpm", debug.strategy.runtimeExecutable)
    assert.is_nil(debug.strategy.program)
    assert.has_error(function()
      adapter.build_spec({ tree = tree, vitestCommand = '"unterminated' })
    end)
  end)

  async.it("reads and removes its report, failing closed when it is missing", function()
    local adapter = require("neotest-vitest")({})
    local tree = tree_for(root .. "/src/nested.test.ts")
    local test = tree:children()[1]:children()[1]:children()[1]
    local spec = adapter.build_spec({ tree = test })
    local missing = adapter.results(spec, { code = 1, output = "out" }, test)
    assert.are.equal("failed", missing[test:data().id].status)
    assert.is_truthy(missing[test:data().id].short:find("missing", 1, true))

    vim.fn.writefile({
      vim.json.encode({
        success = true,
        testResults = {
          {
            name = root .. "/src/nested.test.ts",
            status = "passed",
            assertionResults = {
              {
                ancestorTitles = { "first level", "second level" },
                title = "foo",
                status = "passed",
                failureMessages = {},
              },
            },
          },
        },
      }),
    }, spec.context.results_path)
    local results = adapter.results(spec, { code = 0, output = "out" }, test)
    assert.are.equal("passed", results[test:data().id].status)
    assert.is_nil(vim.uv.fs_stat(spec.context.results_path))
  end)

  async.it("ignores the DAP strategy's placeholder exit code but not unhandled errors", function()
    local adapter = require("neotest-vitest")({})
    local tree = tree_for(root .. "/src/nested.test.ts")
    local test = tree:children()[1]:children()[1]:children()[1]
    local green = vim.json.encode({
      success = true,
      testResults = {
        {
          name = root .. "/src/nested.test.ts",
          status = "passed",
          assertionResults = {
            {
              ancestorTitles = { "first level", "second level" },
              title = "foo",
              status = "passed",
              failureMessages = {},
            },
          },
        },
      },
    })
    local output = vim.fn.tempname()
    local function run(strategy, log)
      local spec = adapter.build_spec({ tree = test, strategy = strategy })
      vim.fn.writefile({ green }, spec.context.results_path)
      vim.fn.writefile(vim.split(log, "\n"), output)
      return adapter.results(spec, { code = 1, output = output }, test)[test:data().id]
    end

    -- js-debug sends no exited event, so Neotest reports 1 for a clean run.
    local debugged = run(
      "dap",
      "JSON report written\n[neotest] DAP session ended without an event_exited exitCode"
    )
    assert.are.equal("passed", debugged.status)
    -- Unhandled errors still fail an all-green debug run.
    local unhandled = run("dap", "Vitest caught 1 unhandled error during the test run.")
    assert.are.equal("failed", unhandled.status)
    assert.is_truthy(unhandled.short:find("exited with code 1", 1, true))
    -- Without a debugger the process exit code stays authoritative.
    assert.are.equal("failed", run(nil, "").status)
  end)
end)
