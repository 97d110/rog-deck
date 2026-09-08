import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Api.js" as Api

// Bar label for ROG Deck: the CPU temperature and the active performance
// profile, coloured against the same thresholds the panel uses. Click opens
// the panel; Panel.qml owns the controls.
//
// Shape follows the first-party widgets (see panels/clock/BarWidget.qml):
// the bar tracks this widget, so open/close/opened and the popout-switch
// hooks are forwarded down to the nested panel.
BarWidget {
  id: root
  moduleName: "rog-deck"

  property var snapshot: null
  property string profile: ""
  property bool reachable: false

  readonly property var cpu: Api.warmestCpu(snapshot)
  readonly property string cpuText: cpu ? Math.round(cpu.celsius) + "°" : "--"
  readonly property string profileText: profile === "" ? "" : profile.charAt(0).toUpperCase()
  readonly property string displayText: reachable
    ? (profileText === "" ? cpuText : cpuText + " " + profileText)
    : "rog?"

  readonly property color stateColour: {
    if (!reachable) return Qt.darker(button.foreground, 1.6)
    var l = Api.level(cpu ? cpu.celsius : null, cpu ? cpu.range : null)
    if (l === "bad") return Color.urgent
    if (l === "warn") return Color.accent
    return button.foreground
  }

  function refresh() {
    Api.get("/api/sensors", function (data, err) {
      root.reachable = err === null
      if (data) root.snapshot = data
    })
    Api.get("/api/state", function (data, err) {
      if (data && data.profile) root.profile = data.profile.current || ""
    })
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  // ---- panel plumbing, mirroring the first-party widgets ----
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight:
    Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  readonly property bool popoutSwitchClosing:
    panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Component.onCompleted: refresh()

  // Slow enough to be invisible in top(1); the panel polls faster while open.
  Timer {
    interval: 4000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "rog-deck"

    function refresh(): void { root.refresh() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.displayText
    labelVisible: !root.vertical
    hasVisualContent: true
    horizontalMargin: 8.75
    verticalPadding: 8.75
    foreground: root.stateColour

    onPressed: function (b) {
      if (b === Qt.RightButton) root.refresh()
      else root.togglePanel()
    }

    // Vertical bars get the temperature stacked, matching how the other
    // icon widgets collapse.
    OpticalGlyph {
      visible: root.vertical
      anchors.centerIn: parent
      width: button.width
      height: Style.bar.iconSlot
      text: root.cpuText
      fontFamily: button.fontFamily
      fontSize: button.fontSize * 0.9
      color: root.stateColour
    }
  }
}
