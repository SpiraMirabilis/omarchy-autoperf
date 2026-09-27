import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar icon and settings panel for the autoperf daemon (daemon/). The daemon
// reads ~/.config/omarchy-autoperf/config and re-reads it on change, so every control
// here just rewrites that file; the on/off switch enables the user unit.
Panel {
  id: root
  moduleName: "io.github.spiramirabilis.autoperf"
  ipcTarget: "omarchy-autoperf"

  property var config: Model.parseConfig("")
  property var daemonState: Model.parseState("")
  // systemctl is-enabled / is-active for the unit. Assume installed until the
  // first check says otherwise, so the panel does not open on the setup prompt.
  property string unitEnabled: "disabled"
  property string unitActive: ""
  property bool writePending: false

  property bool cursorActive: false
  property int cursorRow: 0

  readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy-autoperf/config"
  readonly property string statePath: Quickshell.env("XDG_RUNTIME_DIR") + "/omarchy-autoperf/state"
  readonly property string setupPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/" + moduleName + "/setup"

  readonly property bool installed: unitEnabled !== "not-found"
  readonly property bool enabled: unitEnabled === "enabled"
  readonly property bool boosted: enabled && daemonState.state === "boosted"
  readonly property bool running: enabled && daemonState.state !== ""
  readonly property bool failed: enabled && unitActive === "failed"
  readonly property string statusText: failed
    ? "Daemon failed to start"
    : Model.statusText(installed, enabled, daemonState)

  // Keyboard rows, top to bottom. Setting rows are named after config keys.
  readonly property var rows: installed
    ? ["power", "boost_from", "up", "idle", "idle_secs", "drop_to", "ac_only"]
    : ["setup"]
  readonly property string cursorKey: cursorActive ? rows[Math.min(cursorRow, rows.length - 1)] : ""

  readonly property var boostFromOptions: Model.BOOST_FROM.map(function(v) { return { value: v, label: Model.profileLabel(v) } })
  readonly property var dropToOptions: Model.DROP_TO.map(function(v) { return { value: v, label: Model.profileLabel(v) } })

  function refresh() {
    if (!unitProc.running && !actionProc.running) unitProc.running = true
    stateFile.reload()
  }

  function toggleEnabled() {
    if (!installed || actionProc.running) return
    // Flip optimistically so the switch throws immediately; the status query
    // after the action settles it to the real unit state.
    var enable = !enabled
    unitEnabled = enable ? "enabled" : "disabled"
    actionProc.command = ["systemctl", "--user", enable ? "enable" : "disable", "--now", "omarchy-autoperf.service"]
    actionProc.running = true
  }

  function runSetup() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", setupPath])
    close()
  }

  function setConfig(key, value) {
    var next = Object.assign({}, config)
    next[key] = value
    config = next
    saveTimer.restart()
  }

  function setThreshold(key, value) {
    config = Model.setThreshold(config, key, value)
    saveTimer.restart()
  }

  function writeConfig() {
    if (writeProc.running) {
      writePending = true
      return
    }
    // Written beside the target and renamed over it, so the daemon never
    // reads a half-written file.
    writeProc.command = ["sh", "-c", 'mkdir -p -- "$(dirname -- "$1")" && printf "%s" "$2" > "$1.tmp" && mv -f -- "$1.tmp" "$1"',
      "autoperf-panel", configPath, Model.serializeConfig(config)]
    writeProc.running = true
  }

  function hoverRow(key) {
    var index = rows.indexOf(key)
    if (index < 0) return
    cursorActive = true
    cursorRow = index
  }

  // Up/down walks the rows; left/right changes the value on the current row.
  function moveCursor(dx, dy) {
    if (dy !== 0) {
      cursorRow = Model.clamp(cursorRow + dy, 0, rows.length - 1)
      return
    }
    var key = cursorKey
    if (key === "boost_from") setConfig(key, Model.stepChoice(Model.BOOST_FROM, config.boost_from, dx))
    else if (key === "drop_to") setConfig(key, Model.stepChoice(Model.DROP_TO, config.drop_to, dx))
    else if (Model.LIMITS[key]) setThreshold(key, config[key] + dx * Model.LIMITS[key].step)
  }

  function activateCursor() {
    var key = cursorKey
    if (key === "power") toggleEnabled()
    else if (key === "ac_only") setConfig("ac_only", !config.ac_only)
    else if (key === "setup") runSetup()
  }

  onOpenedChanged: {
    if (!opened) return
    refresh()
    configFile.reload()
    cursorActive = false
    cursorRow = 0
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

  FileView {
    id: configFile
    path: root.configPath
    printErrors: false
    // Don't let a load that started before an edit roll the edit back.
    onLoaded: if (!saveTimer.running && !writeProc.running) root.config = Model.parseConfig(text())
    onLoadFailed: if (!saveTimer.running && !writeProc.running) root.config = Model.parseConfig("")
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    // The daemon rewrites the file in place; skip the empty read a watcher can
    // catch between truncate and write.
    onLoaded: if (text().trim() !== "") root.daemonState = Model.parseState(text())
    onLoadFailed: root.daemonState = Model.parseState("")
  }

  // The watcher loses the state file when the daemon stops and removes it, so
  // also poll: often while the panel is open, lazily for the bar icon.
  Timer {
    interval: root.opened ? 1000 : 5000
    running: true
    repeat: true
    onTriggered: root.opened ? root.refresh() : stateFile.reload()
  }

  Timer {
    id: saveTimer
    interval: 300
    onTriggered: root.writeConfig()
  }

  Process {
    id: unitProc
    command: ["sh", "-c", "systemctl --user is-enabled omarchy-autoperf.service; systemctl --user is-active omarchy-autoperf.service"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = text.split("\n")
        root.unitEnabled = (lines[0] || "").trim() || "not-found"
        root.unitActive = (lines[1] || "").trim()
      }
    }
  }

  Process {
    id: actionProc
    onExited: root.refresh()
  }

  Process {
    id: writeProc
    onExited: {
      if (!root.writePending) return
      root.writePending = false
      root.writeConfig()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰓅"
    dimmed: !root.running
    active: root.boosted
    activeColor: Color.accent
    tooltipText: root.statusText
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleEnabled()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: icon · title/status · on/off switch ----------
        PanelHero {
          id: hero
          width: parent.width
          title: "Auto Performance"
          meta: root.statusText
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          iconOpacity: root.running ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: "󰓅"
              color: root.boosted ? Color.accent : root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display

              Behavior on color { ColorAnimation { duration: 200 } }
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              visible: root.installed
              checked: root.enabled
              busy: actionProc.running
              hasCursor: root.cursorKey === "power"
              foreground: root.bar.foreground
              onHovered: function(on) { if (on) root.hoverRow("power") }
              onToggled: root.toggleEnabled()
            }
          }
        }

        // ---------- Not installed: point at the setup script ----------
        Column {
          visible: !root.installed
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "The autoperf daemon isn't installed yet. Setup builds it (installing Rust if needed) and adds a systemd user service."
            color: root.bar.foreground
            opacity: 0.7
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Button {
            text: "Run setup"
            iconText: "󰏗"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            hasCursor: root.cursorKey === "setup"
            onClicked: root.runSetup()
            onHovered: function(h) { if (h) root.hoverRow("setup") }
          }
        }

        // ---------- Settings ----------
        Column {
          visible: root.installed
          width: parent.width
          spacing: Style.space(14)

          PanelSeparator { foreground: root.bar.foreground }

          PanelSectionHeader {
            text: "BOOST TO PERFORMANCE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          ChoiceRow {
            key: "boost_from"
            label: "From"
            options: root.boostFromOptions
          }

          SliderRow {
            key: "up"
            label: "When CPU reaches"
            valueText: root.config.up + "%"
          }

          PanelSeparator { foreground: root.bar.foreground }

          PanelSectionHeader {
            text: "DROP BACK"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          SliderRow {
            key: "idle"
            label: "When CPU falls to"
            valueText: root.config.idle + "%"
          }

          SliderRow {
            key: "idle_secs"
            label: "For"
            valueText: root.config.idle_secs + (root.config.idle_secs === 1 ? " second" : " seconds")
          }

          ChoiceRow {
            key: "drop_to"
            label: "To"
            options: root.dropToOptions
          }

          PanelSeparator { foreground: root.bar.foreground }

          Toggle {
            width: parent.width
            label: "Only on AC power"
            description: root.config.ac_only ? "Paused while on battery" : "Also boosts on battery"
            checked: root.config.ac_only
            hasCursor: root.cursorKey === "ac_only"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            titleSize: Style.font.bodySmall
            onClicked: root.setConfig("ac_only", !root.config.ac_only)
            onHovered: function(h) { if (h) root.hoverRow("ac_only") }
          }
        }
      }
    }
  }

  // A labelled pick-one row (profile choices).
  component ChoiceRow: Column {
    id: choiceRow
    property string key: ""
    property string label: ""
    property var options: []
    readonly property bool hasCursor: root.cursorKey === key

    width: parent.width
    spacing: Style.space(6)

    RowLabel { text: choiceRow.label; hot: choiceRow.hasCursor }

    ButtonGroup {
      id: group
      options: choiceRow.options
      value: String(root.config[choiceRow.key])
      focusable: false
      cursorIndex: choiceRow.hasCursor ? group.selectedOptionIndex() : -1
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
      fontSize: Style.font.bodySmall
      onChanged: function(v) { root.setConfig(choiceRow.key, v) }
      onHovered: function(index, h) { if (h) root.hoverRow(choiceRow.key) }
    }
  }

  // A labelled slider with its current value on the right.
  component SliderRow: Column {
    id: sliderRow
    property string key: ""
    property string label: ""
    property string valueText: ""
    readonly property bool hasCursor: root.cursorKey === key
    readonly property var limit: Model.LIMITS[key] || { min: 0, max: 1, step: 1 }

    width: parent.width
    spacing: Style.space(2)

    Item {
      width: parent.width
      implicitHeight: Math.max(rowLabel.implicitHeight, rowValue.implicitHeight)

      RowLabel { id: rowLabel; text: sliderRow.label; hot: sliderRow.hasCursor }

      Text {
        id: rowValue
        anchors.right: parent.right
        textFormat: Text.PlainText
        text: sliderRow.valueText
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
    }

    PanelSlider {
      bar: root.bar
      width: parent.width
      minimum: sliderRow.limit.min
      maximum: sliderRow.limit.max
      step: sliderRow.limit.step
      integer: true
      value: root.config[sliderRow.key]
      onMoved: function(v) { root.setThreshold(sliderRow.key, v) }
    }

    HoverHandler {
      onHoveredChanged: if (hovered) root.hoverRow(sliderRow.key)
    }
  }

  component RowLabel: Text {
    property bool hot: false
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: hot ? 1.0 : 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
