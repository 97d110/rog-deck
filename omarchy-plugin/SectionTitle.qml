import QtQuick
import qs.Commons
import qs.Ui

// A section header with an optional explanation behind an (i).
Row {
  id: root

  property string text: ""
  property string info: ""
  property var host: null
  property color foreground: Color.menu.text

  spacing: Style.spacing.sm

  PanelSectionHeader {
    text: root.text
    foreground: root.foreground
    anchors.verticalCenter: parent.verticalCenter
  }

  InfoTip {
    visible: root.info !== ""
    text: root.info
    host: root.host
    foreground: root.foreground
    anchors.verticalCenter: parent.verticalCenter
  }
}
