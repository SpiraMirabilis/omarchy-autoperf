// Run with: node Model.test.js
var assert = require("assert")
var M = require("./Model.js")

function run(name, fn) {
  try {
    fn()
    console.log("ok   " + name)
  } catch (e) {
    console.log("FAIL " + name + "\n     " + e.message)
    process.exitCode = 1
  }
}

run("empty file gives defaults", function() {
  assert.deepStrictEqual(M.parseConfig(""), M.DEFAULTS)
})

run("parses every key", function() {
  var c = M.parseConfig("# comment\nenabled=false\nboost_from=both\nup = 75\nup_samples=3\nidle=5\n"
    + "idle_secs=20\ndrop_to=power-saver\nac_only=false\ninterval=2\n")
  assert.deepStrictEqual(c, {
    enabled: false, boost_from: "both", up: 75, up_samples: 3, idle: 5,
    idle_secs: 20, drop_to: "power-saver", ac_only: false, interval: 2
  })
})

run("bad values fall back and out-of-range values are clamped", function() {
  var c = M.parseConfig("up=150\nboost_from=turbo\nup_samples=0\nbogus\nidle=-3\ninterval=abc\n")
  assert.strictEqual(c.up, 100)
  assert.strictEqual(c.boost_from, "balanced")
  assert.strictEqual(c.up_samples, 1)
  assert.strictEqual(c.idle, 0)
  assert.strictEqual(c.interval, 1)
})

run("idle stays below up", function() {
  assert.strictEqual(M.parseConfig("up=50\nidle=50").idle, 49)
  assert.strictEqual(M.parseConfig("up=20\nidle=30").idle, 19)
  assert.deepStrictEqual(M.setThreshold({ up: 50, idle: 10 }, "idle", 50).up, 51)
  assert.deepStrictEqual(M.setThreshold({ up: 60, idle: 30 }, "up", 20).idle, 19)
  assert.deepStrictEqual(M.setThreshold({ up: 100, idle: 10 }, "idle", 50).up, 100)
})

run("serialize round-trips", function() {
  var c = M.parseConfig("up=85\nidle=40\nidle_secs=30\ndrop_to=balanced\nenabled=false")
  assert.deepStrictEqual(M.parseConfig(M.serializeConfig(c)), c)
  assert.ok(M.sameConfig(c, M.parseConfig(M.serializeConfig(c))))
  assert.ok(!M.sameConfig(c, M.DEFAULTS))
})

run("cpu ticks and busy percent", function() {
  var a = M.cpuTicks("cpu  100 0 50 800 50 0 0 0 0 0\ncpu0 1 2 3\n")
  assert.deepStrictEqual(a, { total: 1000, idle: 850 })
  var b = { total: 1100, idle: 880 }
  assert.strictEqual(M.busyPercent(a, b), 70)
  assert.strictEqual(M.busyPercent(a, a), null)
  assert.strictEqual(M.busyPercent(null, b), null)
  assert.strictEqual(M.cpuTicks("intr 1 2 3"), null)
  assert.strictEqual(M.cpuTicks(""), null)
})

run("boost after up_samples hot samples, from a boostable profile", function() {
  var c = M.DEFAULTS
  var r = M.step(M.initialState(), c, 90, "balanced")
  assert.strictEqual(r.set, "")
  assert.strictEqual(r.state.hot, 1)
  r = M.step(r.state, c, 90, "balanced")
  assert.strictEqual(r.set, "performance")
  assert.strictEqual(r.state.mode, "loaded")
  assert.strictEqual(r.state.restore, "balanced")
})

run("a cool sample resets the hot count", function() {
  var c = M.DEFAULTS
  var r = M.step(M.initialState(), c, 90, "balanced")
  r = M.step(r.state, c, 30, "balanced")
  assert.strictEqual(r.state.hot, 0)
  assert.strictEqual(r.state.mode, "normal")
})

run("spike on a profile not to boost from is left alone", function() {
  var c = M.DEFAULTS
  var s = M.initialState()
  var r = M.step(M.step(s, c, 99, "performance").state, c, 99, "performance")
  assert.strictEqual(r.set, "")
  assert.strictEqual(r.state.mode, "loaded")
  assert.strictEqual(r.state.restore, "")
  // ...and nothing is switched when it ends.
  var st = r.state
  for (var i = 0; i < 10; i++) { r = M.step(st, c, 1, "performance"); st = r.state }
  assert.strictEqual(r.set, "")
  assert.strictEqual(st.mode, "normal")
})

run("drops back after idle_secs of idle, honoring drop_to", function() {
  var c = M.normalize({ drop_to: "power-saver", idle_secs: 3, interval: 1 })
  var st = { mode: "loaded", restore: "power-saver", hot: 0, quiet: 0 }
  var r = M.step(st, c, 5, "performance"); st = r.state
  r = M.step(st, c, 50, "performance"); st = r.state   // busy sample resets quiet
  assert.strictEqual(st.quiet, 0)
  r = M.step(st, c, 5, "performance"); st = r.state
  r = M.step(st, c, 5, "performance"); st = r.state
  assert.strictEqual(r.set, "")
  r = M.step(st, c, 5, "performance")
  assert.strictEqual(r.set, "power-saver")
  assert.strictEqual(r.state.mode, "normal")
  assert.strictEqual(r.state.restore, "")
})

run("idle_secs is rounded up to whole intervals", function() {
  var c = M.normalize({ idle_secs: 5, interval: 2 })
  var st = { mode: "loaded", restore: "balanced", hot: 0, quiet: 0 }
  var r
  for (var i = 0; i < 2; i++) { r = M.step(st, c, 0, "performance"); st = r.state }
  assert.strictEqual(r.set, "")
  r = M.step(st, c, 0, "performance")
  assert.strictEqual(r.set, "balanced")
})

run("a profile changed by someone else while boosted is left alone", function() {
  var c = M.normalize({ idle_secs: 1 })
  var st = { mode: "loaded", restore: "balanced", hot: 0, quiet: 0 }
  var r = M.step(st, c, 0, "power-saver")
  assert.strictEqual(r.set, "")
  assert.strictEqual(r.state.mode, "normal")
})

run("boost_from and drop_to helpers", function() {
  assert.ok(M.boostFromIncludes("both", "power-saver"))
  assert.ok(!M.boostFromIncludes("balanced", "power-saver"))
  assert.ok(!M.boostFromIncludes("both", "performance"))
  assert.strictEqual(M.dropTarget("previous", "power-saver"), "power-saver")
  assert.strictEqual(M.dropTarget("balanced", "power-saver"), "balanced")
  assert.strictEqual(M.profileName(2), "performance")
  assert.strictEqual(M.profileIndex("balanced"), 1)
  assert.strictEqual(M.profileName(7), "")
})

run("status text", function() {
  assert.strictEqual(M.statusText("boosted", "power-saver", 71.6), "Boosted · back to power saver · 72% CPU")
  assert.strictEqual(M.statusText("watching", "", null), "Watching CPU load")
  assert.strictEqual(M.statusText("off", "", 3), "Off")
  assert.strictEqual(M.stepChoice(M.BOOST_FROM, "bogus", 1), "power-saver")
  assert.strictEqual(M.stepChoice(M.DROP_TO, "power-saver", 1), "power-saver")
})
