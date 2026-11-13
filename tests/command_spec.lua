local command = require("neotest-vitest.command")

local function write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ content or "" }, path)
end

describe("argv", function()
  it("copies argv lists without splitting arguments", function()
    local input = { "pnpm", "exec", "vitest", "name with spaces" }
    local argv = command.argv(input)
    assert.are.same(input, argv)
    argv[1] = "changed"
    assert.are.equal("pnpm", input[1])
  end)

  it("tokenises legacy strings without a shell", function()
    assert.are.same({ "pnpm", "exec", "vitest" }, command.argv("pnpm exec vitest"))
    assert.are.same({ "yarn", "vitest", "--watch" }, command.argv("  yarn   vitest --watch "))
    assert.are.same(
      { "/my path/vitest", "run", "a b" },
      command.argv('"/my path/vitest" run a\\ b')
    )
    assert.are.same({ "echo", "$HOME", "`id`", ";", "|" }, command.argv("echo $HOME `id` ; |"))
    assert.are.same({ "pnpm", "", "vitest" }, command.argv('pnpm "" vitest'))
  end)

  it("keeps Windows drive and UNC paths literal", function()
    assert.are.same(
      { "C:\\Program Files\\nodejs\\node.exe", "C:\\repo\\node_modules\\vitest\\vitest.mjs" },
      command.argv(
        '"C:\\Program Files\\nodejs\\node.exe" C:\\repo\\node_modules\\vitest\\vitest.mjs'
      )
    )
    assert.are.same(
      { "\\\\server\\share\\tools\\vitest.exe", "--run" },
      command.argv('"\\\\server\\share\\tools\\vitest.exe" --run')
    )
  end)

  it("treats an existing executable path with spaces as one word", function()
    local dir = vim.fn.tempname() .. " ünïcödé dir"
    local binary = dir .. "/node_modules/.bin/vitest"
    write(binary, "#!/bin/sh")
    assert.are.same({ binary }, command.argv(binary))
    vim.fn.delete(dir, "rf")
  end)

  it("rejects malformed commands deterministically", function()
    for _, value in ipairs({
      {},
      "",
      "   ",
      '"unterminated',
      { [1] = "a", [3] = "b" },
      { "" },
      { 1 },
      42,
    }) do
      local argv, err = command.argv(value)
      assert.is_nil(argv)
      assert.is_string(err)
    end
  end)
end)

describe("default_argv", function()
  local root
  before_each(function()
    root = vim.fn.tempname() .. " work tree"
    write(root .. "/.git", "gitdir: /elsewhere")
    write(root .. "/node_modules/.bin/vitest", "#!/bin/sh")
    write(root .. "/node_modules/vitest/vitest.mjs", "")
    write(root .. "/node_modules/vitest/package.json", '{"version":"5.1.0"}')
    write(root .. "/packages/a/src/a.test.ts", "")
  end)
  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("uses the nearest checkout-local runner", function()
    local argv = command.default_argv(root .. "/packages/a/src/a.test.ts")
    if command.is_windows then
      assert.are.same({ "node", root .. "/node_modules/vitest/vitest.mjs" }, argv)
    else
      assert.are.same({ root .. "/node_modules/.bin/vitest" }, argv)
    end
    assert.are.equal(
      5,
      command.vitest_major(command.vitest_entry(root .. "/packages/a/src/a.test.ts"))
    )
  end)

  it("prefers a nested package's own installation", function()
    write(root .. "/packages/a/node_modules/.bin/vitest", "#!/bin/sh")
    write(root .. "/packages/a/node_modules/vitest/vitest.mjs", "")
    local argv = command.default_argv(root .. "/packages/a/src/a.test.ts")
    assert.is_truthy(argv[#argv]:find("/packages/a/node_modules/", 1, true))
  end)

  it("never crosses into an enclosing checkout", function()
    local nested = root .. "/vendor/other"
    write(nested .. "/.git/HEAD", "ref: refs/heads/main")
    write(nested .. "/x.test.ts", "")
    assert.are.same({ "vitest" }, command.default_argv(nested .. "/x.test.ts"))
    assert.is_nil(command.vitest_entry(nested .. "/x.test.ts"))
  end)
end)

describe("options", function()
  it("detects explicit long, camel, negated and spaced options", function()
    assert.is_true(command.has_option({ "--testTimeout", "100" }, command.test_timeout_options))
    assert.is_true(command.has_option({ "--test-timeout=100" }, command.test_timeout_options))
    assert.is_true(
      command.has_option({ "--no-file-parallelism" }, command.file_parallelism_options)
    )
    assert.is_true(
      command.has_option({ "--fileParallelism=true" }, command.file_parallelism_options)
    )
    assert.is_false(command.has_option({ "--test-timeouts" }, command.test_timeout_options))
  end)

  it("resolves the effective watch mode from the last flag", function()
    assert.is_true(command.watches({ "vitest", "--watch" }))
    assert.is_true(command.watches({ "vitest", "watch" }))
    assert.is_false(command.watches({ "vitest", "--watch", "--watch=false" }))
    assert.is_false(command.watches({ "vitest", "-w", "--run" }))
    assert.is_false(command.watches({ "vitest" }))
  end)
end)

describe("dap_config", function()
  it("launches Vitest's entrypoint with Node when the adapter owns the runner", function()
    local config = command.dap_config(
      { "/r/node_modules/.bin/vitest", "--a", "b c" },
      "/r/node_modules/vitest/vitest.mjs"
    )
    assert.are.equal("pwa-node", config.type)
    assert.are.equal("node", config.runtimeExecutable)
    assert.are.equal("/r/node_modules/vitest/vitest.mjs", config.program)
    assert.are.same({ "--a", "b c" }, config.args)
    assert.is_true(config.autoAttachChildProcesses)
    assert.is_true(config.sourceMaps)
    assert.is_nil(config.env)
    assert.is_nil(config.cwd)
  end)

  it("does not pass a Windows Node entrypoint twice", function()
    local config = command.dap_config({ "node", "C:/r/vitest.mjs", "--x" }, "C:/r/vitest.mjs")
    assert.are.same({ "--x" }, config.args)
  end)

  it("keeps a caller's package-manager argv unchanged", function()
    local config = command.dap_config({ "pnpm", "exec", "vitest", "--x" }, nil)
    assert.are.equal("pnpm", config.runtimeExecutable)
    assert.is_nil(config.program)
    assert.are.same({ "exec", "vitest", "--x" }, config.args)
  end)
end)
