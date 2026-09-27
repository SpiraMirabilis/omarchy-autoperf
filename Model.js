// Settings file shared with the daemon (daemon/src/main.rs). Keep the
// defaults and limits in step with Config::default() and Config::parse().

var DEFAULTS = {
  boost_from: "balanced",
  up: 60,
  up_samples: 2,
  idle: 10,
  idle_secs: 10,
  drop_to: "previous",
  ac_only: true,
  interval: 1
}

var BOOST_FROM = ["balanced", "power-saver", "both"]
var DROP_TO = ["previous", "balanced", "power-saver"]

// Ranges offered by the panel sliders.
var LIMITS = {
  up: { min: 20, max: 100, step: 5 },
  idle: { min: 0, max: 50, step: 1 },
  idle_secs: { min: 1, max: 120, step: 1 }
}

// Every key is written back, so hand-edited up_samples/interval survive.
var KEY_ORDER = ["boost_from", "up", "up_samples", "idle", "idle_secs", "drop_to", "ac_only", "interval"]

function clamp(value, lo, hi) {
  return Math.max(lo, Math.min(hi, value))
}

function withDefaults(config) {
  var c = {}
  for (var key in DEFAULTS) c[key] = DEFAULTS[key]
  for (var k in config || {}) c[k] = config[k]
  return c
}

function parseConfig(raw) {
  var c = withDefaults({})
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line || line.charAt(0) === "#") continue
    var eq = line.indexOf("=")
    if (eq <= 0) continue
    var key = line.substring(0, eq).trim()
    var value = line.substring(eq + 1).trim()

    if (key === "boost_from" && BOOST_FROM.indexOf(value) >= 0) c.boost_from = value
    else if (key === "drop_to" && DROP_TO.indexOf(value) >= 0) c.drop_to = value
    else if (key === "ac_only" && (value === "true" || value === "false")) c.ac_only = value === "true"
    else if (key in DEFAULTS && typeof DEFAULTS[key] === "number" && value !== "" && isFinite(Number(value))) c[key] = Number(value)
  }
  return c
}

function serializeConfig(config) {
  var c = withDefaults(config)
  var out = "# autoperf settings, written by the Auto Performance panel.\n"
    + "# Edits here are picked up by the daemon within a second.\n"
  for (var i = 0; i < KEY_ORDER.length; i++) {
    var key = KEY_ORDER[i]
    out += key + "=" + String(c[key]) + "\n"
  }
  return out
}

// Keep idle below up, moving whichever one was not just edited.
function setThreshold(config, key, value) {
  var c = withDefaults(config)
  var limit = LIMITS[key]
  c[key] = clamp(Math.round(value), limit.min, limit.max)
  if (key === "up" && c.idle >= c.up) c.idle = Math.max(LIMITS.idle.min, c.up - 1)
  if (key === "idle" && c.idle >= c.up) c.up = clamp(c.idle + 1, LIMITS.up.min, LIMITS.up.max)
  if (c.idle >= c.up) c.idle = c.up - 1
  return c
}

// Step through a list of choices, clamped at the ends.
function stepChoice(list, value, delta) {
  var index = list.indexOf(value)
  if (index < 0) index = 0
  return list[clamp(index + delta, 0, list.length - 1)]
}

// $XDG_RUNTIME_DIR/autoperf/state: "state=watching|boosted|paused" plus
// "restore=<profile>" while boosted. An empty or missing file means the daemon
// is not running.
function parseState(raw) {
  var s = { state: "", restore: "" }
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var eq = lines[i].indexOf("=")
    if (eq <= 0) continue
    var key = lines[i].substring(0, eq).trim()
    if (key === "state" || key === "restore") s[key] = lines[i].substring(eq + 1).trim()
  }
  return s
}

function profileLabel(name) {
  if (name === "power-saver") return "Power saver"
  if (name === "previous") return "Previous"
  if (name === "both") return "Both"
  return String(name || "").charAt(0).toUpperCase() + String(name || "").slice(1)
}

// installed: unit file present; enabled: unit enabled; state: from parseState.
function statusText(installed, enabled, state) {
  if (!installed) return "Daemon not installed"
  if (!enabled) return "Off"
  if (state.state === "boosted") return state.restore ? "Boosted · back to " + profileLabel(state.restore).toLowerCase() : "Boosted"
  if (state.state === "paused") return "Paused on battery"
  if (state.state === "watching") return "Watching CPU load"
  return "Starting"
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULTS: DEFAULTS,
    BOOST_FROM: BOOST_FROM,
    DROP_TO: DROP_TO,
    LIMITS: LIMITS,
    clamp: clamp,
    parseConfig: parseConfig,
    serializeConfig: serializeConfig,
    setThreshold: setThreshold,
    stepChoice: stepChoice,
    parseState: parseState,
    profileLabel: profileLabel,
    statusText: statusText
  }
}
