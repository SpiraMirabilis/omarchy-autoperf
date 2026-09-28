import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar icon and settings panel. All the work happens in Service.qml, which the
// shell loads once; this widget (one per screen) only shows its state and
// hands edits to it.
Panel {
  id: root
  moduleName: "io.github.spiramirabilis.autoperf"
  ipcTarget: "omarchy-autoperf"

  readonly property var service: root.bar && root.bar.shell ? root.bar.shell.serviceFor(root.moduleName) : null
  readonly property var config: service ? service.config : Model.parseConfig("")
  readonly property string status: service ? service.status : ""
  readonly property bool enabled: config.enabled === true
  readonly property bool boosted: status === "boosted"
  readonly property bool running: status === "watching" || status === "boosted"
  readonly property string statusText: service
    ? Model.statusText(status, service.restore, service.cpu)
    : "Service not loaded"

  property bool cursorActive: false
  property int cursorRow: 0

  // Keyboard rows, top to bottom. Setting rows are named after config keys.
  readonly property var rows: ["power", "boost_from", "up", "idle", "idle_secs", "drop_to", "ac_only"]
  readonly property string cursorKey: cursorActive ? rows[Math.min(cursorRow, rows.length - 1)] : ""

  readonly property var boostFromOptions: Model.BOOST_FROM.map(function(v) { return { value: v, label: Model.profileLabel(v) } })
  readonly property var dropToOptions: Model.DROP_TO.map(function(v) { return { value: v, label: Model.profileLabel(v) } })

  function toggleEnabled() {
    if (service) service.toggleEnabled()
  }

  function setConfig(key, value) {
    if (service) service.setConfig(key, value)
  }

  function setThreshold(key, value) {
    if (service) service.setThreshold(key, value)
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
  }

  onOpenedChanged: {
    if (!opened) return
    cursorActive = false
    cursorRow = 0
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

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
              checked: root.enabled
              interactive: root.service !== null
              hasCursor: root.cursorKey === "power"
              foreground: root.bar.foreground
              onHovered: function(on) { if (on) root.hoverRow("power") }
              onToggled: root.toggleEnabled()
            }
          }
        }

        // ---------- No performance profile on this machine ----------
        Text {
          visible: root.status === "unavailable"
          textFormat: Text.PlainText
          width: parent.width
          text: "power-profiles-daemon reports no performance profile on this machine, so there is nothing to boost to."
          color: root.bar.foreground
          opacity: 0.7
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // ---------- Settings ----------
        Column {
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
