// Pure logic shared by Service.qml (sampling and switching) and Panel.qml
// (display and editing). No Qt in here, so `node Model.test.js` can run it.

var DEFAULTS = {
  enabled: true,
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

// Ranges offered by the panel sliders. Values read from the file are clamped
// to these too, so the panel and the sampler always agree.
var LIMITS = {
  up: { min: 20, max: 100, step: 5 },
  idle: { min: 0, max: 50, step: 1 },
  idle_secs: { min: 1, max: 120, step: 1 },
  up_samples: { min: 1, max: 60, step: 1 },
  interval: { min: 1, max: 60, step: 1 }
}

// Every key is written back, so hand-edited up_samples/interval survive.
var KEY_ORDER = ["enabled", "boost_from", "up", "up_samples", "idle", "idle_secs", "drop_to", "ac_only", "interval"]

// Quickshell's PowerProfile enum: PowerSaver = 0, Balanced = 1, Performance = 2.
var PROFILE_NAMES = ["power-saver", "balanced", "performance"]

function profileName(index) {
  return PROFILE_NAMES[index] || ""
}

function profileIndex(name) {
  return PROFILE_NAMES.indexOf(name)
}

function clamp(value, lo, hi) {
  return Math.max(lo, Math.min(hi, value))
}

function withDefaults(config) {
  var c = {}
  for (var key in DEFAULTS) c[key] = DEFAULTS[key]
  for (var k in config || {}) c[k] = config[k]
  return c
}

// Bring a config into range: numbers clamped to LIMITS, idle kept below up.
function normalize(config) {
  var c = withDefaults(config)
  for (var key in LIMITS) {
    var n = Number(c[key])
    if (!isFinite(n)) n = DEFAULTS[key]
    c[key] = clamp(Math.round(n), LIMITS[key].min, LIMITS[key].max)
  }
  if (c.idle >= c.up) c.idle = Math.max(LIMITS.idle.min, c.up - 1)
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
    else if ((key === "ac_only" || key === "enabled") && (value === "true" || value === "false")) c[key] = value === "true"
    else if (key in LIMITS && value !== "" && isFinite(Number(value))) c[key] = Number(value)
  }
  return normalize(c)
}

function serializeConfig(config) {
  var c = normalize(config)
  var out = "# Auto Performance settings, written by the bar panel.\n"
    + "# Edits here are picked up live. up_samples and interval are file-only.\n"
  for (var i = 0; i < KEY_ORDER.length; i++) {
    var key = KEY_ORDER[i]
    out += key + "=" + String(c[key]) + "\n"
  }
  return out
}

function sameConfig(a, b) {
  for (var i = 0; i < KEY_ORDER.length; i++) {
    var key = KEY_ORDER[i]
    if (a[key] !== b[key]) return false
  }
  return true
}

// Keep idle below up, moving whichever one was not just edited.
function setThreshold(config, key, value) {
  var c = withDefaults(config)
  var limit = LIMITS[key]
  c[key] = clamp(Math.round(value), limit.min, limit.max)
  if (key === "idle" && c.idle >= c.up) c.up = clamp(c.idle + 1, LIMITS.up.min, LIMITS.up.max)
  return normalize(c)
}

// Step through a list of choices, clamped at the ends.
function stepChoice(list, value, delta) {
  var index = list.indexOf(value)
  if (index < 0) index = 0
  return list[clamp(index + delta, 0, list.length - 1)]
}

// ---------------------------------------------------------------- sampling

// Total and idle jiffies from the aggregate `cpu` line of /proc/stat, or null.
// Fields: user nice system idle iowait irq softirq steal (guest is in user).
function cpuTicks(procStat) {
  var line = String(procStat || "").split("\n")[0]
  var fields = line.trim().split(/\s+/)
  if (fields[0] !== "cpu" || fields.length < 5) return null
  var total = 0
  var idle = 0
  for (var i = 1; i < fields.length && i <= 8; i++) {
    var n = Number(fields[i])
    if (!isFinite(n)) return null
    total += n
    if (i === 4 || i === 5) idle += n
  }
  return { total: total, idle: idle }
}

// Busy percentage between two tick readings, or null when there is no delta.
function busyPercent(prev, cur) {
  if (!prev || !cur) return null
  var dt = cur.total - prev.total
  if (dt <= 0) return null
  var di = clamp(cur.idle - prev.idle, 0, dt)
  return 100 * (dt - di) / dt
}

// ------------------------------------------------------------ state machine

// mode "normal": waiting for a spike. mode "loaded": in a spike, waiting for
// idle; `restore` is the profile to drop to afterwards, or "" when the spike
// was left alone because the active profile was not one to boost from.
function initialState() {
  return { mode: "normal", restore: "", hot: 0, quiet: 0 }
}

function boostFromIncludes(boostFrom, profile) {
  if (boostFrom === "both") return profile === "balanced" || profile === "power-saver"
  return profile === boostFrom
}

function dropTarget(dropTo, previous) {
  return dropTo === "previous" ? previous : dropTo
}

// Feed one CPU sample. Returns the next state and the profile to switch to,
// if any ("" for none).
function step(state, c, busy, profile) {
  var s = { mode: state.mode, restore: state.restore, hot: state.hot, quiet: state.quiet }
  var set = ""
  if (s.mode === "normal") {
    s.hot = busy >= c.up ? s.hot + 1 : 0
    if (s.hot >= c.up_samples) {
      s.hot = 0
      s.quiet = 0
      s.mode = "loaded"
      if (boostFromIncludes(c.boost_from, profile)) {
        s.restore = dropTarget(c.drop_to, profile)
        set = "performance"
      } else {
        s.restore = ""
      }
    }
  } else {
    s.quiet = busy <= c.idle ? s.quiet + 1 : 0
    if (s.quiet >= Math.max(1, Math.ceil(c.idle_secs / c.interval))) {
      s.quiet = 0
      s.mode = "normal"
      // Only drop back if nobody changed the profile while boosted.
      if (s.restore && profile === "performance") set = s.restore
      s.restore = ""
    }
  }
  return { state: s, set: set }
}

// ------------------------------------------------------------------ display

function profileLabel(name) {
  if (name === "power-saver") return "Power saver"
  if (name === "previous") return "Previous"
  if (name === "both") return "Both"
  return String(name || "").charAt(0).toUpperCase() + String(name || "").slice(1)
}

// status: off | unavailable | paused | watching | boosted (from Service.qml).
function statusText(status, restore, cpu) {
  var load = cpu === null || cpu === undefined ? "" : " · " + Math.round(cpu) + "% CPU"
  if (status === "off") return "Off"
  if (status === "unavailable") return "No performance profile"
  if (status === "paused") return "Paused on battery"
  if (status === "boosted") return (restore ? "Boosted · back to " + profileLabel(restore).toLowerCase() : "Boosted") + load
  if (status === "watching") return "Watching CPU load" + load
  return "Starting"
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULTS: DEFAULTS,
    BOOST_FROM: BOOST_FROM,
    DROP_TO: DROP_TO,
    LIMITS: LIMITS,
    PROFILE_NAMES: PROFILE_NAMES,
    profileName: profileName,
    profileIndex: profileIndex,
    clamp: clamp,
    normalize: normalize,
    parseConfig: parseConfig,
    serializeConfig: serializeConfig,
    sameConfig: sameConfig,
    setThreshold: setThreshold,
    stepChoice: stepChoice,
    cpuTicks: cpuTicks,
    busyPercent: busyPercent,
    initialState: initialState,
    boostFromIncludes: boostFromIncludes,
    dropTarget: dropTarget,
    step: step,
    profileLabel: profileLabel,
    statusText: statusText
  }
}
