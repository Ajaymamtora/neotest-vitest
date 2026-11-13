-- Test name selection for neotest-vitest.
--
-- Builds the `--testNamePattern` regular expression for a Neotest position and
-- the matching Lua predicate used to attribute reported (runtime) titles back
-- to discovered (source) positions. Parameterised titles (`test.each`,
-- `test.for`, `describe.each`, template literals with substitutions) contain
-- printf/`$field`/`${expr}` placeholders whose runtime text is unknown until
-- Vitest runs; each placeholder becomes a wildcard.
local M = {}

---Split a title into literal text and wildcard placeholders.
---@param name string
---@param parameterized boolean
---@return { literal?: string, wild?: boolean }[]
function M.segments(name, parameterized)
  if not parameterized then
    return { { literal = name } }
  end
  local segments, literal = {}, {}
  local function flush()
    if #literal > 0 then
      segments[#segments + 1] = { literal = table.concat(literal) }
      literal = {}
    end
  end
  local function wild()
    flush()
    if not (segments[#segments] and segments[#segments].wild) then
      segments[#segments + 1] = { wild = true }
    end
  end
  local i = 1
  while i <= #name do
    local char, next_char = name:sub(i, i), name:sub(i + 1, i + 1)
    if char == "%" and next_char == "%" then
      literal[#literal + 1] = "%"
      i = i + 2
    elseif char == "%" and next_char:match("^[sdifjoOc#%$]$") then
      wild()
      i = i + 2
    elseif char == "$" and next_char == "{" then
      local close = name:find("}", i + 2, true)
      if not close then
        literal[#literal + 1] = char
        i = i + 1
      else
        wild()
        i = close + 1
      end
    elseif char == "$" and next_char:match("^[%a_]$") then
      -- `$field`, `$a.b` and `$a.0` object-case interpolation.
      local _, finish = name:find("^%$[%a_][%w_]*", i)
      while true do
        local _, more = name:find("^%.[%w_]+", finish + 1)
        if not more then
          break
        end
        finish = more
      end
      wild()
      i = finish + 1
    else
      literal[#literal + 1] = char
      i = i + 1
    end
  end
  flush()
  return segments
end

local function escape_regex(text)
  return (text:gsub("[%^%$%.%*%+%?%(%)%[%]{}|/\\%-]", "\\%0"):gsub("%s", "\\s"))
end

local function regex(segments)
  local parts = {}
  for _, segment in ipairs(segments) do
    parts[#parts + 1] = segment.wild and ".*?" or escape_regex(segment.literal)
  end
  return table.concat(parts)
end

---Lua predicate matching a reported title against a discovered position.
---@param name string
---@param parameterized boolean
---@return fun(title: string): boolean
function M.matcher(name, parameterized)
  if not parameterized then
    return function(title)
      return title == name
    end
  end
  local parts = {}
  for _, segment in ipairs(M.segments(name, true)) do
    parts[#parts + 1] = segment.wild and ".-" or vim.pesc(segment.literal)
  end
  local lua_pattern = "^" .. table.concat(parts) .. "$"
  return function(title)
    return title == name or title:find(lua_pattern) ~= nil
  end
end

---Separator and prefix of the full test name Vitest matches against.
---Vitest 1 prefixes the root suite (an empty space); Vitest 2-4 join titles
---with a space; Vitest 5 joins them with " > ". When the version is unknown
---accept every form.
---@param major integer|nil
---@return string prefix, string separator
function M.syntax(major)
  if major == nil then
    return "^\\s?", "\\s(?:>\\s)?"
  elseif major >= 5 then
    return "^", "\\s>\\s"
  elseif major >= 2 then
    return "^", "\\s"
  end
  return "^\\s?", "\\s"
end

---@class neotest-vitest.PatternName
---@field name string
---@field parameterized? boolean

---Regular expression selecting a namespace or test.
---@param names neotest-vitest.PatternName[] outermost namespace first
---@param kind "test"|"namespace"
---@param major integer|nil installed Vitest major version
---@return string|nil
function M.build(names, kind, major)
  if #names == 0 then
    return nil
  end
  local prefix, separator = M.syntax(major)
  local parts = {}
  for _, item in ipairs(names) do
    parts[#parts + 1] = regex(M.segments(item.name, item.parameterized == true))
  end
  local body = prefix .. table.concat(parts, separator)
  if kind == "test" then
    return body .. "$"
  end
  -- A namespace must be followed by a separator, so `math` cannot select
  -- the sibling suite `mathematics`.
  return body .. separator
end

return M
