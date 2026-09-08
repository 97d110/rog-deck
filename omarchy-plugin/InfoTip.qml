import QtQuick
import qs.Commons

// A small (i) beside a section title. Hovering asks the host to show an
// explanation.
//
// The tip itself is drawn by the host, in the window's top layer, because the
// panel's scrolling container has clip: true - a tooltip declared here as a
// child would be cut off at the edge of the scroll view.
Item {
  id: root

  property string text: ""
  property var host: null            // must provide showTip(text, item) / hideTip()
  property color foreground: Color.menu.text

  implicitWidth: Math.max(Style.space(15), glyph.implicitWidth)
  implicitHeight: implicitWidth

  Rectangle {
    id: ring
    anchors.fill: parent
    radius: width / 2
    color: mouse.containsMouse
      ? Qt.alpha(Color.accent, 0.25) : Qt.alpha(root.foreground, 0.10)
    border.width: 1
    border.color: mouse.containsMouse
      ? Color.accent : Qt.alpha(root.foreground, 0.35)

    Behavior on color { ColorAnimation { duration: 120 } }
    Behavior on border.color { ColorAnimation { duration: 120 } }
  }

  Text {
    id: glyph
    anchors.centerIn: parent
    text: "i"
    color: mouse.containsMouse ? Color.accent : Qt.darker(root.foreground, 1.3)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption * 0.95
    font.bold: true
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: if (root.host && root.text !== "") root.host.showTip(root.text, root)
    onExited: if (root.host) root.host.hideTip()
    // Tapping is the same as hovering, for touch and for people who click.
    onClicked: if (root.host && root.text !== "") root.host.showTip(root.text, root)
  }
}
