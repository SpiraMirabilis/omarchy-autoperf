import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "Model.js" as Model

// The sampler. Loaded once by the shell (the bar widget is created once per
// screen, so it must not do this itself): reads /proc/stat on a timer, and
// switches the power profile through Quickshell's in-process D-Bus binding
// to power-profiles-daemon.
//
// Settings live in ~/.config/omarchy-autoperf/config, watched for hand edits
// and rewritten by the panel through setConfig(). An active boost is noted in
// $XDG_RUNTIME_DIR so it survives a shell restart and is still dropped when
// the load goes away; the runtime dir is cleared at logout, when Omarchy
// applies its saved profile anyway.
Item {
  id: root

  property var shell: null

  readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy-autoperf/config"
  readonly property string boostPath: Quickshell.env("XDG_RUNTIME_DIR") + "/omarchy-autoperf/boost"

  property var config: Model.parseConfig("")
  property var state: Model.initialState()
  // Last busy percentage, or null while not sampling.
  property var cpu: null
  property var prevTicks: null
  // Restore target read from the boost file, applied once the profile is known.
  property string pendingRestore: ""
  property string persistedRestore: ""

  readonly property string profile: Model.profileName(PowerProfiles.profile)
  readonly property bool available: PowerProfiles.hasPerformanceProfile
  readonly property bool paused: config.ac_only && UPower.onBattery
  readonly property bool sampling: config.enabled && available && !paused
  readonly property bool boosted: state.mode === "loaded" && state.restore !== ""
  readonly property string restore: boosted ? state.restore : ""
  readonly property string status: !config.enabled ? "off"
    : !available ? "unavailable"
    : paused ? "paused"
    : boosted ? "boosted"
    : "watching"

  // ---------------------------------------------------------------- settings

  function setConfig(key, value) {
    var next = Object.assign({}, config)
    next[key] = value
    applyConfig(next)
  }

  function setThreshold(key, value) {
    applyConfig(Model.setThreshold(config, key, value))
  }

  function toggleEnabled() {
    setConfig("enabled", !config.enabled)
  }

  // From the panel: take effect now, write the file shortly.
  function applyConfig(next) {
    if (!adoptConfig(next)) return
    saveTimer.restart()
  }

  // From the file: hand edits, or our own write coming back.
  function adoptConfig(next) {
    next = Model.normalize(next)
    if (Model.sameConfig(next, config)) return false
    config = next
    // Thresholds moved: start counting afresh.
    state = Object.assign({}, state, { hot: 0, quiet: 0 })
    // Switched off, or ac_only turned on while on battery: let go now.
    if (!sampling) endBoost(config.enabled ? "paused" : "switched off")
    return true
  }

  // ---------------------------------------------------------------- sampling

  function setProfile(name) {
    var index = Model.profileIndex(name)
    if (index < 0) return
    PowerProfiles.profile = index
  }

  function sample(procStat) {
    var ticks = Model.cpuTicks(procStat)
    var busy = Model.busyPercent(prevTicks, ticks)
    prevTicks = ticks
    if (busy === null) return
    cpu = busy

    var r = Model.step(state, config, busy, profile)
    var wasBoosted = boosted
    state = r.state
    if (r.set === "performance") console.log("autoperf: load spike, " + profile + " -> performance")
    else if (r.set) console.log("autoperf: idle, performance -> " + r.set)
    else if (wasBoosted && !boosted) console.log("autoperf: idle, profile was changed to " + profile + " meanwhile, leaving it")
    if (r.set) setProfile(r.set)
    persistBoost()
  }

  // Forget the current spike without touching the profile.
  function resetState() {
    state = Model.initialState()
    prevTicks = null
    persistBoost()
  }

  // Drop back now, if we are the ones holding performance.
  function endBoost(reason) {
    if (boosted && profile === "performance") {
      console.log("autoperf: " + reason + ", performance -> " + state.restore)
      setProfile(state.restore)
    }
    resetState()
  }

  onSamplingChanged: {
    prevTicks = null
    if (!sampling) cpu = null
  }

  onAvailableChanged: if (available) resumeBoost()

  // Omarchy applies its saved profile for the new power source, which ends
  // any boost; forget it rather than later "restoring" over that choice.
  Connections {
    target: UPower
    function onOnBatteryChanged() { root.resetState() }
  }

  // Someone else picked a profile while boosted: their choice stands.
  Connections {
    target: PowerProfiles
    function onProfileChanged() {
      if (root.boosted && root.profile !== "performance") root.resetState()
    }
  }

  Timer {
    interval: root.config.interval * 1000
    running: root.sampling
    repeat: true
    triggeredOnStart: true
    onTriggered: statFile.reload()
  }

  FileView {
    id: statFile
    path: "/proc/stat"
    printErrors: false
    onLoaded: if (root.sampling) root.sample(text())
  }

  Component.onDestruction: {
    // Plugin disabled, removed or reloaded. The boost file is left as is: a
    // replacement instance sees the profile is no longer performance and
    // clears it.
    if (boosted && profile === "performance") setProfile(state.restore)
  }

  // ------------------------------------------------------------ boost record

  function persistBoost() {
    if (restore === persistedRestore) return
    persistedRestore = restore
    boostWriter.write(restore)
  }

  function resumeBoost() {
    if (!pendingRestore) return
    var to = pendingRestore
    pendingRestore = ""
    if (config.enabled && profile === "performance" && Model.profileIndex(to) >= 0) {
      console.log("autoperf: resuming boost, back to " + to + " after idle")
      state = { mode: "loaded", restore: to, hot: 0, quiet: 0 }
      persistedRestore = to
    } else {
      boostWriter.write("")
    }
  }

  FileView {
    id: boostFile
    path: root.boostPath
    printErrors: false
    onLoaded: {
      root.pendingRestore = text().trim()
      if (root.available) root.resumeBoost()
    }
  }

  // ------------------------------------------------------------- config file

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    // Don't let a load that started before an edit roll the edit back.
    onLoaded: if (!saveTimer.running && !configWriter.running) root.adoptConfig(Model.parseConfig(text()))
    onLoadFailed: if (!saveTimer.running && !configWriter.running) root.adoptConfig(Model.parseConfig(""))
  }

  Timer {
    id: saveTimer
    interval: 300
    onTriggered: configWriter.write(Model.serializeConfig(root.config))
  }

  Writer { id: configWriter; path: root.configPath; atomic: true }
  Writer { id: boostWriter; path: root.boostPath }

  // Writes a file, creating its folder. Coalesces writes issued while one is
  // still running. `atomic` renames a temp file over the target.
  component Writer: Process {
    id: writer
    property string path: ""
    property bool atomic: false
    property var pending: null

    function write(text) {
      if (running) {
        pending = text
        return
      }
      command = ["sh", "-c",
        'mkdir -p -- "$(dirname -- "$1")" && if [ "$3" = 1 ]; then printf "%s" "$2" > "$1.tmp" && mv -f -- "$1.tmp" "$1"; else printf "%s" "$2" > "$1"; fi',
        "autoperf-writer", path, text, atomic ? "1" : "0"]
      running = true
    }

    onExited: function(code) {
      if (code !== 0) console.warn("autoperf: could not write " + path)
      if (pending === null) return
      var text = pending
      pending = null
      write(text)
    }
  }

  // ------------------------------------------------------------- migration

  // Versions before 0.3 ran a Rust daemon as a systemd user unit. Remove it if
  // it is still there, but only the files that carry the old setup's marks.
  Process {
    id: oldDaemonCleanup
    command: ["sh", "-c",
      'unit="$HOME/.config/systemd/user/omarchy-autoperf.service"\n'
      + 'if [ -f "$unit" ] && [ ! -L "$unit" ] && [ "$(head -n1 "$unit")" = "# Installed by the io.github.spiramirabilis.autoperf Omarchy plugin" ]; then\n'
      + '  systemctl --user disable --now omarchy-autoperf.service 2>/dev/null\n'
      + '  rm -f -- "$unit" && systemctl --user daemon-reload\n'
      + '  echo "autoperf: removed the old omarchy-autoperf daemon unit"\n'
      + 'fi\n'
      + 'lib="$HOME/.local/lib/omarchy-autoperf"\n'
      + 'if [ -d "$lib" ] && [ ! -L "$lib" ] && [ -f "$lib/.owner" ] && [ "$(cat "$lib/.owner")" = "io.github.spiramirabilis.autoperf" ]; then\n'
      + '  rm -rf -- "$lib" && echo "autoperf: removed the old daemon binary"\n'
      + 'fi']
    stdout: StdioCollector { onStreamFinished: if (text.trim() !== "") console.log(text.trim()) }
  }

  Component.onCompleted: oldDaemonCleanup.running = true
}
