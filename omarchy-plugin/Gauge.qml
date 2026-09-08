import QtQuick
import qs.Commons

// One reading placed between idle and that part's own ceiling. The zone
// colouring is what lets a non-expert tell "warm" from "about to throttle",
// so it uses the ranges the service reports rather than fixed thresholds.
Item {
  id: root

  property string label: ""
  property real value: 0
  property string unit: ""
  property int decimals: 0
  property var range: null
  property string limitWord: "throttles"
  property bool plain: false      // no danger end, e.g. battery charge
  property color foreground: Color.menu.text

  readonly property real rMin: range ? range.min : 0
  readonly property real rMax: range ? range.max : 100
  readonly property real rWarn: range ? range.warn : 70
  readonly property real rCrit: range ? range.crit : 90
  readonly property real span: Math.max(0.0001, rMax - rMin)
  readonly property real fraction: Math.max(0, Math.min(1, (value - rMin) / span))

  readonly property color okColour: Qt.rgba(0.42, 0.78, 0.42, 1)
  readonly property color warnColour: Color.accent
  readonly property color badColour: Color.urgent
  readonly property color stateColour: plain
    ? Color.accent
    : (value >= rCrit ? badColour : (value >= rWarn ? warnColour : okColour))

  implicitHeight: name.implicitHeight + track.height + ticks.implicitHeight
                  + Style.spacing.xxs * 2

  Text {
    id: name
    text: root.label
    color: Qt.darker(root.foreground, 1.35)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    anchors.left: parent.left
  }

  Text {
    id: reading
    text: root.value.toFixed(root.decimals) + root.unit
    color: root.stateColour
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    anchors.right: parent.right
    anchors.baseline: name.baseline
  }

  Rectangle {
    id: track
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: name.bottom
    anchors.topMargin: Style.spacing.xxs
    height: Math.max(6, Style.space(7))
    color: Qt.darker(Color.menu.background, 1.4)
    border.width: 1
    border.color: Qt.alpha(root.foreground, 0.25)
    radius: Style.cornerRadius

    // Faint zones behind the fill so the danger end is visible before the
    // value gets there.
    Row {
      anchors.fill: parent
      anchors.margins: 1
      visible: !root.plain
      opacity: 0.22
      Rectangle {
        width: parent.width * Math.max(0, Math.min(1, (root.rWarn - root.rMin) / root.span))
        height: parent.height
        color: root.okColour
      }
      Rectangle {
        width: parent.width * Math.max(0, Math.min(1, (root.rCrit - root.rWarn) / root.span))
        height: parent.height
        color: root.warnColour
      }
      Rectangle {
        width: Math.max(0, parent.width - x)
        height: parent.height
        color: root.badColour
      }
    }

    Rectangle {
      x: 1
      y: 1
      width: Math.max(0, (parent.width - 2) * root.fraction)
      height: parent.height - 2
      color: root.stateColour
      Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutQuad } }
    }
  }

  Item {
    id: ticks
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: track.bottom
    anchors.topMargin: Style.spacing.xxs
    implicitHeight: low.implicitHeight

    Text {
      id: low
      text: Math.round(root.rMin) + root.unit
      color: Qt.darker(root.foreground, 1.8)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption * 0.85
      anchors.left: parent.left
    }

    Text {
      visible: !root.plain && root.limitWord !== ""
      text: root.limitWord + " " + Math.round(root.rCrit) + root.unit
        + (root.range && root.range.source === "estimate" ? " (est)" : "")
      color: Qt.darker(root.foreground, 1.8)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption * 0.85
      anchors.horizontalCenter: parent.horizontalCenter
    }

    Text {
      text: Math.round(root.rMax) + root.unit
      color: Qt.darker(root.foreground, 1.8)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption * 0.85
      anchors.right: parent.right
    }
  }
}
