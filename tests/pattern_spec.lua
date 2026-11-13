local pattern = require("neotest-vitest.pattern")

describe("test name pattern", function()
  it("uses the full-name syntax of each Vitest major", function()
    local names = { { name = "math" }, { name = "adds" } }
    assert.are.equal("^math\\s>\\sadds$", pattern.build(names, "test", 5))
    assert.are.equal("^math\\sadds$", pattern.build(names, "test", 4))
    assert.are.equal("^math\\sadds$", pattern.build(names, "test", 2))
    assert.are.equal("^\\s?math\\sadds$", pattern.build(names, "test", 1))
    assert.are.equal("^\\s?math\\s(?:>\\s)?adds$", pattern.build(names, "test", nil))
  end)

  it("requires a separator after a namespace", function()
    assert.are.equal("^math\\s>\\s", pattern.build({ { name = "math" } }, "namespace", 5))
    assert.are.equal(
      "^\\s?math\\s(?:>\\s)?",
      pattern.build({ { name = "math" } }, "namespace", nil)
    )
  end)

  it("escapes every regular expression metacharacter", function()
    local built = pattern.build({ { name = "a.b*c+d?e^f$g(h)i[j]k{l}m|n/o\\p-q" } }, "test", 4)
    assert.are.equal("^a\\.b\\*c\\+d\\?e\\^f\\$g\\(h\\)i\\[j\\]k\\{l\\}m\\|n\\/o\\\\p\\-q$", built)
  end)

  it("keeps Unicode and literal placeholders of ordinary tests", function()
    assert.are.equal("^ünï\\s%s\\s\\$x$", pattern.build({ { name = "ünï %s $x" } }, "test", 4))
  end)

  it("turns parameterised placeholders into wildcards", function()
    local built = pattern.build({
      { name = "dyn %s", parameterized = true },
      { name = "case $a.b %d of %% ${n}", parameterized = true },
    }, "test", 5)
    assert.are.equal("^dyn\\s.*?\\s>\\scase\\s.*?\\s.*?\\sof\\s%\\s.*?$", built)
  end)
end)

describe("matcher", function()
  it("matches ordinary titles exactly", function()
    local match = pattern.matcher("adds (1)", false)
    assert.is_true(match("adds (1)"))
    assert.is_false(match("adds (1) more"))
  end)

  it("matches runtime titles of parameterised positions", function()
    local match = pattern.matcher("each %i works", true)
    assert.is_true(match("each 1 works"))
    assert.is_true(match("each 12 works"))
    assert.is_false(match("each 1 fails"))
    local object = pattern.matcher("obj $a.b ok (%%)", true)
    assert.is_true(object("obj {x} ok (%)"))
    assert.is_false(object("obj 1 ok"))
    local template = pattern.matcher("loop ${n} [x]", true)
    assert.is_true(template("loop 2 [x]"))
  end)
end)
