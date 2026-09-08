import QtQuick
import qs.Commons

// A DragSlider with a caption label above it and the live value on the right.
// Commits on release so a drag sends one write, not forty - and never on
// scroll, so scrolling the page cannot change a power limit.
Item {
  id: root

  property string label: ""
  property string hint: ""
  property real value: 0
  property real minimum: 0
  property real maximum: 1
  property real step: 0.05
  property string unit: ""
  property int decimals: 0
  property color foreground: Color.menu.text
  property bool interactive: true

  signal committed(real value)

  readonly property real rowHeight:
    caption.implicitHeight + slider.controlHeight + Style.spacing.xxs
  implicitHeight: rowHeight
  height: rowHeight

  Text {
    id: caption
    anchors.left: parent.left
    text: root.label + (root.hint === "" ? "" : "  · " + root.hint)
    color: Qt.darker(root.foreground, 1.35)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
    width: parent.width - reading.width - Style.spacing.sm
  }

  Text {
    id: reading
    anchors.right: parent.right
    anchors.baseline: caption.baseline
    text: slider.liveValue.toFixed(root.decimals) + root.unit
    color: Color.accent
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  DragSlider {
    id: slider
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: caption.bottom
    anchors.topMargin: Style.spacing.xxs
    interactive: root.interactive
    minimum: root.minimum
    maximum: root.maximum
    step: root.step
    value: root.value
    onReleased: function (v) { root.committed(v) }
  }
}
