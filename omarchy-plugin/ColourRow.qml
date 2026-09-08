import QtQuick
import qs.Commons

// A labelled row of colour swatches. Preset choices rather than a colour
// wheel: a handful of good options is quicker to hit, and the selected one is
// always visible, which a picker button is not.
Column {
  id: root

  property string label: ""
  property string hint: ""
  property var swatches: []
  property string current: ""
  property color foreground: Color.menu.text

  signal picked(string colour)

  spacing: Style.spacing.xs

  Text {
    visible: root.label !== ""
    width: parent.width
    text: root.label + (root.hint === "" ? "" : "  · " + root.hint)
    color: Qt.darker(root.foreground, 1.35)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }

  Row {
    spacing: Style.spacing.sm

    Repeater {
      model: root.swatches

      Rectangle {
        id: chip
        required property string modelData
        readonly property bool checked:
          String(root.current).toLowerCase() === String(modelData).toLowerCase()

        width: Style.space(32)
        height: Style.space(22)
        radius: Style.cornerRadius
        color: modelData
        border.width: chip.checked ? Math.max(2, Style.space(2))
                                   : (hover.containsMouse ? Math.max(1, Style.space(1)) : 1)
        border.color: chip.checked ? root.foreground : Qt.alpha(root.foreground, 0.35)
        scale: hover.containsMouse && !chip.checked ? 1.08 : 1

        Behavior on scale { NumberAnimation { duration: 90 } }
        Behavior on border.color { ColorAnimation { duration: 120 } }

        MouseArea {
          id: hover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.picked(chip.modelData)
        }
      }
    }
  }
}
