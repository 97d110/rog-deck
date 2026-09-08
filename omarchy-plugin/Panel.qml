import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Api.js" as Api

// ROG Deck's panel, built from the shared shell components so it reads like
// the network and bluetooth panels: PanelSectionHeader labels, PanelSeparator
// rules, Toggle rows, PanelSlider controls, and Color/Style tokens throughout
// - which means it re-themes with `omarchy theme set` for free.
//
// All state comes from the rog-deck HTTP service, which already owns the
// privileged paths. BarWidget.qml owns the bar label and anchors this panel.
Panel {
  id: root
  moduleName: "rog-deck"
  ipcTarget: "rog-deck"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property var state: null
  property var snapshot: null
  property string errorText: ""

  readonly property var profileInfo: state && state.profile ? state.profile : null
  readonly property var ripple: state && state.ripple ? state.ripple : null
  readonly property var aura: state && state.aura ? state.aura : null
  readonly property var cpu: Api.warmestCpu(snapshot)
  readonly property var dgpu: snapshot && snapshot.dgpu ? snapshot.dgpu : null

  readonly property color fg: Color.popups.text
  readonly property color dim: Qt.darker(fg, 1.5)

  // Preset swatches instead of a colour wheel: a handful of good choices is
  // faster to hit than a picker, and matches how the shell offers options
  // elsewhere.
  readonly property var swatches: [
    "#3caaff", "#98c379", "#e5c07b", "#ff2d55", "#c678dd", "#ffffff"
  ]

  function refresh() {
    Api.get("/api/state", function (data, err) {
      root.errorText = err === null ? "" : err
      if (data) root.state = data
    })
    Api.get("/api/sensors", function (data, err) {
      if (data) root.snapshot = data
    })
  }

  function send(path, body) {
    Api.post(path, body, function (data, err) {
      root.errorText = err === null ? "" : err
      root.refresh()
    })
  }

  onOpenedChanged: if (opened) refresh()

  // Only poll while the panel is on screen.
  Timer {
    interval: 1500
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
    }

    Column {
      id: content
      width: parent.width
      spacing: Style.spacing.md

      // ---- hero: what this machine is doing right now ----
      Column {
        width: parent.width
        spacing: Style.spacing.xxs

        Text {
          text: root.profileInfo ? root.profileInfo.current : "…"
          color: root.fg
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.capitalization: Font.Capitalize
        }

        Text {
          text: {
            var bits = []
            if (root.cpu) bits.push("CPU " + Math.round(root.cpu.celsius) + "°")
            if (root.dgpu && root.dgpu.celsius !== null)
              bits.push("GPU " + Math.round(root.dgpu.celsius) + "°")
            if (root.dgpu && root.dgpu.watts !== null)
              bits.push(root.dgpu.watts.toFixed(1) + " W")
            return bits.length ? bits.join("   ") : "waiting for sensors"
          }
          color: root.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        visible: root.errorText !== ""
        width: parent.width
        wrapMode: Text.WordWrap
        text: root.errorText
        color: Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      PanelSeparator { width: parent.width }
      PanelSectionHeader { text: "Performance profile"; foreground: root.fg }

      Repeater {
        model: root.profileInfo ? root.profileInfo.choices : []

        Toggle {
          required property string modelData
          width: content.width
          label: modelData.charAt(0).toUpperCase() + modelData.slice(1)
          checked: root.profileInfo && root.profileInfo.current === modelData
          foreground: root.fg
          onClicked: root.send("/api/profile", { profile: modelData })
        }
      }

      PanelSeparator { width: parent.width }
      PanelSectionHeader { text: "Keyboard light"; foreground: root.fg }

      Row {
        width: parent.width
        spacing: Style.spacing.sm

        Repeater {
          model: root.aura ? root.aura.brightness_choices : []

          Toggle {
            required property string modelData
            width: (content.width - Style.spacing.sm * 3) / 4
            label: modelData
            checked: root.aura && root.aura.brightness === modelData
            foreground: root.fg
            onClicked: root.send("/api/aura-brightness", { level: modelData })
          }
        }
      }

      // ---- ripple ----
      PanelSeparator {
        width: parent.width
        visible: root.ripple && root.ripple.supported
      }

      PanelSectionHeader {
        text: "Keyboard ripple"
        foreground: root.fg
        visible: root.ripple && root.ripple.supported
      }

      Toggle {
        visible: root.ripple && root.ripple.supported
        width: content.width
        label: "Reactive ripple"
        description: "A wave from each key you press"
        checked: root.ripple && root.ripple.active
        foreground: root.fg
        onClicked: root.send("/api/ripple", { active: !(root.ripple && root.ripple.active) })
      }

      Row {
        visible: root.ripple && root.ripple.supported
        width: parent.width
        spacing: Style.spacing.sm

        Repeater {
          model: root.swatches

          Rectangle {
            required property string modelData
            width: Style.space(28)
            height: Style.space(20)
            color: modelData
            radius: Style.cornerRadius
            border.width: root.ripple && root.ripple.settings
              && root.ripple.settings.colour === modelData ? Math.max(2, Style.space(2)) : 1
            border.color: root.ripple && root.ripple.settings
              && root.ripple.settings.colour === modelData ? root.fg : root.dim

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.send("/api/ripple", { colour: modelData })
            }
          }
        }
      }

      Column {
        visible: root.ripple && root.ripple.supported
        width: parent.width
        spacing: Style.spacing.xxs

        Text {
          text: "Max brightness"
          color: root.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        PanelSlider {
          width: content.width
          bar: root.bar
          minimum: 0
          maximum: 1
          step: 0.05
          value: root.ripple && root.ripple.settings ? root.ripple.settings.brightness : 1
          onReleased: function (v) { root.send("/api/ripple", { brightness: v }) }
        }
      }

      Column {
        visible: root.ripple && root.ripple.supported
        width: parent.width
        spacing: Style.spacing.xxs

        Text {
          text: "Fade time"
          color: root.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        PanelSlider {
          width: content.width
          bar: root.bar
          minimum: 0.05
          maximum: 3
          step: 0.05
          value: root.ripple && root.ripple.settings ? root.ripple.settings.decay : 0.45
          onReleased: function (v) { root.send("/api/ripple", { decay: v }) }
        }
      }
    }
  }
}
