import QtQuick
import qs.Commons

// Single-select radio list.
//
// Toggles were the wrong control here: a Toggle says "this thing is on or
// off", so a row of them for one mutually-exclusive choice reads as several
// independent switches. A radio says "one of these", which is what these
// actually are.
Column {
  id: root

  property string label: ""
  property string hint: ""
  // [{ value, text, description? }]
  property var options: []
  property var current: null
  property bool interactive: true
  property color foreground: Color.menu.text
  property color accent: Color.accent

  signal picked(var value)

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

  Repeater {
    model: root.options

    Rectangle {
      id: row
      required property var modelData
      readonly property bool checked: String(root.current) === String(modelData.value)
      readonly property bool hot: mouse.containsMouse && root.interactive

      width: root.width
      height: text.implicitHeight + (desc.visible ? desc.implicitHeight + Style.spacing.xxs : 0)
              + Style.spacing.md * 2
      radius: Style.cornerRadius
      color: checked
        ? Qt.alpha(root.accent, Style.selectedFillAlpha)
        : (hot ? Qt.alpha(root.foreground, Style.hoverFillAlpha) : "transparent")
      border.width: checked ? Math.max(1, Style.normalBorderWidth) : 0
      border.color: Qt.alpha(root.accent, 0.8)
      opacity: root.interactive ? 1 : 0.45

      Behavior on color { ColorAnimation { duration: 120 } }

      // ---- the radio mark ----
      Rectangle {
        id: mark
        width: Style.space(14)
        height: width
        radius: width / 2
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        color: "transparent"
        border.width: Math.max(1, Style.space(2))
        border.color: row.checked ? root.accent
                                  : Qt.alpha(root.foreground, row.hot ? 0.75 : 0.45)

        Behavior on border.color { ColorAnimation { duration: 120 } }

        Rectangle {
          anchors.centerIn: parent
          width: parent.width * (row.checked ? 0.5 : 0)
          height: width
          radius: width / 2
          color: root.accent
          // The dot springing in is the whole point of preferring a radio:
          // there is somewhere for the selection to actually happen.
          Behavior on width {
            NumberAnimation { duration: 160; easing.type: Easing.OutBack }
          }
        }
      }

      Text {
        id: text
        anchors.left: mark.right
        anchors.leftMargin: Style.spacing.md
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.md
        anchors.top: parent.top
        anchors.topMargin: Style.spacing.md
        text: row.modelData.text
        color: row.checked ? root.foreground : Qt.darker(root.foreground, 1.2)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        id: desc
        visible: !!row.modelData.description
        anchors.left: text.left
        anchors.right: text.right
        anchors.top: text.bottom
        anchors.topMargin: Style.spacing.xxs
        text: row.modelData.description || ""
        color: Qt.darker(root.foreground, 1.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: root.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: if (root.interactive) root.picked(row.modelData.value)
      }
    }
  }
}
