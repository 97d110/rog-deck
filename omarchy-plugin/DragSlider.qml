import QtQuick
import qs.Commons

// Click-or-drag slider. Deliberately does NOT handle the scroll wheel.
//
// The shell's PanelSlider does, and it calls released() on every wheel tick -
// so scrolling this app's page committed a hardware write per notch. In a
// scrollable panel full of power limits that is actively dangerous, which is
// why this exists instead.
Item {
  id: root

  property real value: 0
  property real minimum: 0
  property real maximum: 1
  property real step: 0.05
  property bool integer: false
  property bool interactive: true
  property color foreground: Color.menu.text
  property color accent: Color.accent
  property real liveValue: value
  property bool dragging: false

  signal moved(real value)
  signal released(real value)

  readonly property real span: Math.max(0.000001, maximum - minimum)
  readonly property real fraction: Math.max(0, Math.min(1, (liveValue - minimum) / span))

  readonly property real controlHeight:
    Math.max(Style.space(20), Math.max(12, Style.space(14)) + Style.spacing.sm)
  implicitHeight: controlHeight
  height: controlHeight
  opacity: interactive ? 1 : 0.45

  // Follow external changes unless the user is mid-drag.
  onValueChanged: if (!dragging) liveValue = value

  Rectangle {
    id: track
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    height: Math.max(4, Style.space(5))
    radius: Style.cornerRadius
    color: Qt.alpha(root.foreground, 0.18)

    Rectangle {
      width: track.width * root.fraction
      height: parent.height
      radius: parent.radius
      color: root.accent
    }
  }

  Rectangle {
    id: knob
    width: Math.max(12, Style.space(14))
    height: width
    radius: width / 2
    y: (root.height - height) / 2
    x: Math.max(0, Math.min(track.width - width, track.width * root.fraction - width / 2))
    color: root.accent
    border.width: root.dragging || mouse.containsMouse ? Math.max(1, Style.space(2)) : 0
    border.color: Qt.alpha(root.foreground, 0.8)
    scale: root.dragging ? 1.15 : 1
    Behavior on scale { NumberAnimation { duration: 90 } }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    anchors.margins: -Style.spacing.xs
    hoverEnabled: true
    enabled: root.interactive
    cursorShape: root.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
    preventStealing: true   // keep the parent Flickable from grabbing the drag

    function valueAt(x) {
      var usable = Math.max(1, track.width)
      var raw = root.minimum + (Math.max(0, Math.min(usable, x)) / usable) * root.span
      if (root.step > 0) raw = Math.round(raw / root.step) * root.step
      if (root.integer) raw = Math.round(raw)
      return Math.max(root.minimum, Math.min(root.maximum, raw))
    }

    onPressed: function (m) {
      if (m.button !== Qt.LeftButton) return
      root.dragging = true
      root.liveValue = valueAt(m.x)
      root.moved(root.liveValue)
    }
    onPositionChanged: function (m) {
      if (!root.dragging) return
      root.liveValue = valueAt(m.x)
      root.moved(root.liveValue)
    }
    onReleased: function (m) {
      if (m.button !== Qt.LeftButton || !root.dragging) return
      root.dragging = false
      root.released(root.liveValue)
    }
    onCanceled: {
      root.dragging = false
      root.liveValue = root.value
    }
  }
}
