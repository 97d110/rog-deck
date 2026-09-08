import QtQuick
import qs.Commons
import qs.Ui

// A labelled set of mutually exclusive options as Toggle rows. One click
// applies and the checked row always shows real state - deliberately not a
// dropdown, which can display a value the hardware has already moved past.
Column {
  id: root

  property string label: ""
  property string hint: ""
  // [{ value: <any>, text: "..." }]
  property var options: []
  property var current: null
  property bool interactive: true
  property color foreground: Color.menu.text
  property bool horizontal: options.length <= 4

  signal picked(var value)

  spacing: Style.spacing.xs

  Text {
    visible: root.label !== ""
    text: root.label + (root.hint === "" ? "" : "  · " + root.hint)
    color: Qt.darker(root.foreground, 1.35)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    width: parent.width
    elide: Text.ElideRight
  }

  Flow {
    width: parent.width
    spacing: Style.spacing.sm

    Repeater {
      model: root.options

      Toggle {
        required property var modelData
        width: root.horizontal && root.options.length > 1
          ? (root.width - Style.spacing.sm * (root.options.length - 1)) / root.options.length
          : root.width
        label: modelData.text
        checked: String(root.current) === String(modelData.value)
        enabled: root.interactive
        opacity: root.interactive ? 1 : 0.45
        foreground: root.foreground
        onClicked: if (root.interactive) root.picked(modelData.value)
      }
    }
  }
}
