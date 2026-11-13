# neotest-vitest

This plugin provides a [Vitest](https://vitest.dev/) adapter for the [Neotest](https://github.com/rcarriga/neotest) framework.

Credits to [neotest-jest](https://github.com/haydenmeade/neotest-jest)

## About this fork

[Ajaymamtora/neotest-vitest](https://github.com/Ajaymamtora/neotest-vitest) is an MIT
fork of [marilari88/neotest-vitest](https://github.com/marilari88/neotest-vitest). It
changes how runs are built and how results are reported:

- **Runner selection.** The adapter uses the nearest `node_modules/.bin/vitest` inside
  the source file's checkout and never looks past the checkout's `.git`. When the
  package has `node_modules/vitest/vitest.mjs`, Windows runs it with Node directly so
  no `.cmd` shim is executed. Pass `vitestCommand` as an argv table (for example
  `{ "pnpm", "exec", "vitest" }`) to keep it exactly as given. A string is split
  using shell-style quoting, but no shell ever runs it.
- **Version-aware filters.** The `--testNamePattern` value is a fully anchored regex
  built from the installed Vitest's suite separator (`>` from Vitest 5, a space
  before that). Directory runs use a path filter that ends in a separator, so
  `src` cannot also match `src2`.
- **Parameterised tests.** Titles from `test.each`, `describe.each`, `.for` and
  template literals are marked `is_parameterized`. Their placeholders turn into
  wildcards, so one Neotest position runs every generated case. The position takes
  the worst status of those cases.
- **Truthful results.** Vitest's JSON report decides the result. A test is only
  marked passed or failed when its own report entry says so. All of the following
  fail the selection rather than pass it:
  - a missing, empty, oversized or malformed report;
  - an unknown status;
  - a selected test that never ran;
  - a non-zero exit that no reported failure explains.
  Reports for sibling files that matched the path filter (`a.test.ts` also matches
  `a.test.tsx`) are never attributed to the selection.
- **Debugging.** `strategy = "dap"` launches `pwa-node` (vscode-js-debug) with the
  following settings:
  - Vitest's own entrypoint, with source maps, child-process auto-attach and smart
    stepping;
  - `--no-file-parallelism`, `--test-timeout=0` and `--hook-timeout=0`, unless you
    pass your own values;
  - the debuggee's stdout/stderr sent through DAP output events.
  js-debug does not send an `exited` event, so for debug runs only Vitest's
  "unhandled error" banner can turn an all-green report into a failure.

The checks in `tests/` and the end-to-end Neovim + Vitest 1–5 + js-debug harness in
[Ajaymamtora/dotfiles](https://github.com/Ajaymamtora/dotfiles) back these rules.

## Known issues

- `it.todo("title")` without a callback is not shown as a Neotest position; Vitest
  reports it as skipped.
- Vite's SSR transform reads imported bindings through module accessors. A first
  debugger *step into* on `add(...)` can stop at the accessor (line 1 of the
  imported file), and a second step into reaches the function body.

## How to install it

### Lazy.nvim

```lua
{
  "nvim-neotest/neotest",
  dependencies = {
    ...,
    "Ajaymamtora/neotest-vitest",
  },
  config = function()
    require("neotest").setup({
      ...,
      adapters = {
        require("neotest-vitest"),
      }
    })
  end,
}
```

### LazyVim

```lua
{
  "nvim-neotest/neotest",
  dependencies = {
    "Ajaymamtora/neotest-vitest",
  },
  opts = {
    adapters = {
      ["neotest-vitest"] = {},
    },
  },

}
```

### Packer

```lua
use({
  "nvim-neotest/neotest",
  requires = {
    ...,
    "Ajaymamtora/neotest-vitest",
  }
  config = function()
    require("neotest").setup({
      ...,
      adapters = {
        require("neotest-vitest")
      }
    })
  end
})
```

Make sure you have Treesitter installed with the right language parser installed

```
:TSInstall javascript
```

## Configuration

```lua
{
  "nvim-neotest/neotest",
  dependencies = {
    ...,
    "Ajaymamtora/neotest-vitest",
  },
  config = function()
    require("neotest").setup({
      ...,
      adapters = {
        require("neotest-vitest") {
          -- Filter directories when searching for test files. Useful in large projects (see Filter directories notes).
          filter_dir = function(name, rel_path, root)
            return name ~= "node_modules"
          end,
        },
      }
    })
  end,
}
```

### Stricter file parsing to determine test files

Use `is_test_file` option to add a custom criteria for test file discovery.

```lua
---Custom criteria for a file path to determine if it is a vitest test file.
---@async
---@param file_path string Path of the potential vitest test file
---@return boolean
is_test_file = function(file_path)
    -- Check if the project is "my-peculiar-project"
    if string.match(file_path, "my-peculiar-project") then
        -- Check if the file path includes something else
        if string.match(file_path, "/myapp/") then
            -- eg. only files in __tests__ are to be considered
            return string.match(file_path, "__tests__")
        end
    end
    return false
end,
```

### Filter directories

Use `filter_dir` option to limit directories to be searched for tests.

```lua
---Filter directories when searching for test files
---@async
---@param name string Name of directory
---@param rel_path string Path to directory, relative to root
---@param root string Root directory of project
---@return boolean
filter_dir = function(name, rel_path, root)
  local full_path = root .. "/" .. rel_path

  if root:match("projects/my-large-monorepo") then
    if full_path:match("^unit_tests") then
      return true
    else
      return false
    end
  else
    return name ~= "node_modules"
  end
end
```

### Watch mode mappings

```lua

vim.api.nvim_set_keymap(
    "n",
    "<leader>twr",
    "<cmd>lua require('neotest').run.run({ vitestCommand = 'vitest --watch' })<cr>",
    {desc = "Run Watch"}
)

vim.api.nvim_set_keymap(
    "n",
    "<leader>twf",
    "<cmd>lua require('neotest').run.run({ vim.fn.expand('%'), vitestCommand = 'vitest --watch' })<cr>",
    {desc = "Run Watch File"}
)

```

## Usage

![usage preview](https://user-images.githubusercontent.com/32909388/185812063-d05d9cc7-b9aa-43ed-915b-cf156e3f0c52.gif)

See neotest's documentation for more information on how to run tests.

## :gift: Contributing

Please raise a PR if you are interested in adding new functionality or fixing any bugs. When submitting a bug, please include an example spec that can be tested.

To trigger the tests for the adapter, run:

```sh
./scripts/test
```

## Bug Reports

Please file any bug reports and I _might_ take a look if time permits otherwise please submit a PR, this plugin is intended to be by the community for the community.
