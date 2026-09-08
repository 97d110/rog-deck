import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Api.js" as Api

// ROG Deck as an Omarchy app: a summoned overlay, the same shape as the
// command palette and the emoji picker, carrying every control the machine
// exposes.
//
// It shares the [menu] surface tokens, so a theme that styles the command
// palette styles this too, and it is assembled from the shell's own
// components (PanelSectionHeader, PanelSeparator, PanelSlider, Toggle) rather
// than restyled to resemble them.
//
// Summon:  omarchy-shell shell toggle rog-deck
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false

  property var deck: null
  property var snapshot: null
  property string errorText: ""
  property string activeFan: "cpu"
  property var draftCurve: []
  property string auraEffect: ""
  property string auraColour: "#ff0000"

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color borderColour: Color.menu.border
  readonly property var borderSpec:
    Border.surfaceSpec("menu", "border", borderColour, Math.max(1, Style.space(2)))
  readonly property color scrim: Color.menu.scrim
  readonly property color dim: Qt.darker(foreground, 1.45)

  readonly property var attrs: deck && deck.attributes ? deck.attributes : []
  readonly property var profileInfo: deck && deck.profile ? deck.profile : null
  readonly property var battery: deck && deck.battery ? deck.battery : null
  readonly property var aura: deck && deck.aura ? deck.aura : null
  readonly property var slash: deck && deck.slash ? deck.slash : null
  readonly property var graphics: deck && deck.graphics ? deck.graphics : null
  readonly property var numpad: deck && deck.numpad ? deck.numpad : null
  readonly property var ripple: deck && deck.ripple ? deck.ripple : null
  readonly property var curves:
    deck && deck.fan_curves && deck.fan_curves.available ? deck.fan_curves.curves : []
  readonly property var cpu: Api.warmestCpu(snapshot)
  readonly property var dgpu: snapshot && snapshot.dgpu ? snapshot.dgpu : null

  readonly property var swatches: [
    "#3caaff", "#98c379", "#e5c07b", "#ff2d55", "#c678dd", "#ffffff"
  ]

  function attr(name) {
    for (var i = 0; i < attrs.length; i++) if (attrs[i].name === name) return attrs[i]
    return null
  }

  function enumOptions(a, labels) {
    if (!a || !a.choices) return []
    var out = []
    for (var i = 0; i < a.choices.length; i++) {
      var v = a.choices[i]
      out.push({ value: v, text: labels && labels[v] !== undefined ? labels[v] : String(v) })
    }
    return out
  }

  function textOptions(values) {
    var out = []
    for (var i = 0; i < (values || []).length; i++)
      out.push({ value: values[i], text: String(values[i]).replace(/-/g, " ") })
    return out
  }

  function refresh() {
    Api.get("/api/state", function (data, err) {
      root.errorText = err === null ? "" : err
      if (!data) return
      root.deck = data
      root.seedCurve()
    })
    Api.get("/api/sensors", function (data) { if (data) root.snapshot = data })
  }

  function seedCurve() {
    for (var i = 0; i < curves.length; i++) {
      if (curves[i].fan === activeFan) {
        var copy = []
        for (var j = 0; j < curves[i].points.length; j++)
          copy.push({ temp: curves[i].points[j].temp, percent: curves[i].points[j].percent })
        draftCurve = copy
        return
      }
    }
    if (curves.length > 0) { activeFan = curves[0].fan; seedCurve(); return }
    draftCurve = []
  }

  function send(path, body) {
    Api.post(path, body, function (data, err) {
      root.errorText = err === null ? "" : err
      root.refresh()
    })
  }

  function open(payloadJson) { opened = true; refresh() }
  function close() { opened = false }
  function dismiss() { close() }
  function toggle() { opened ? close() : open("") }

  Timer {
    interval: 1500
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: "rog-deck"
    function open(): void { root.open("") }
    function close(): void { root.close() }
    function show(): void { root.open("") }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  PanelWindow {
    id: window
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "rog-deck"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim.a > 0.02
        ? root.scrim
        : Qt.rgba(root.background.r, root.background.g, root.background.b, 0.45)
    }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: Math.min(Style.space(760), window.width - Style.gapsOut * 4)
      height: Math.min(Style.space(720), window.height - Style.gapsOut * 4)
      anchors.centerIn: parent
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec

      // Swallow clicks so they do not reach the dismiss layer behind.
      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding
        focus: root.opened
        Keys.onEscapePressed: root.dismiss()

        // ---- header ----
        Column {
          id: header
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          spacing: Style.spacing.xxs

          Text {
            text: "ROG Deck"
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            text: {
              var bits = []
              if (root.deck && root.deck.model)
                bits.push([root.deck.model.family, root.deck.model.board]
                  .filter(function (v) { return !!v }).join(" · "))
              if (root.cpu) bits.push("CPU " + Math.round(root.cpu.celsius) + "°")
              if (root.dgpu && root.dgpu.celsius !== null)
                bits.push("GPU " + Math.round(root.dgpu.celsius) + "°")
              if (root.snapshot && root.snapshot.power)
                bits.push(root.snapshot.power.on_ac ? "AC" : "battery")
              return bits.join("   ")
            }
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            width: parent.width
            elide: Text.ElideRight
          }

          Text {
            visible: root.errorText !== ""
            text: root.errorText
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            width: parent.width
            wrapMode: Text.WordWrap
          }
        }

        // ---- scrolling body ----
        Flickable {
          id: body
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: header.bottom
          anchors.topMargin: Style.spacing.md
          anchors.bottom: footer.top
          anchors.bottomMargin: Style.spacing.sm
          clip: true
          contentWidth: width
          contentHeight: column.implicitHeight
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: column
            width: body.width - Style.spacing.md
            spacing: Style.spacing.md

            // ===== sensors =====
            PanelSectionHeader { text: "Sensors"; foreground: root.foreground }

            Gauge {
              width: parent.width
              visible: !!root.cpu
              label: "CPU package"
              value: root.cpu ? root.cpu.celsius : 0
              range: root.cpu ? root.cpu.range : null
              unit: "°"; decimals: 1
              foreground: root.foreground
            }

            Gauge {
              width: parent.width
              visible: !!(root.dgpu && root.dgpu.celsius !== null)
              label: root.dgpu && root.dgpu.name
                ? root.dgpu.name.replace("NVIDIA GeForce ", "") : "GPU"
              value: root.dgpu && root.dgpu.celsius !== null ? root.dgpu.celsius : 0
              range: root.dgpu ? root.dgpu.temp_range : null
              unit: "°"
              foreground: root.foreground
            }

            Gauge {
              width: parent.width
              visible: !!(root.dgpu && root.dgpu.watts !== null)
              label: "GPU power draw"
              value: root.dgpu && root.dgpu.watts !== null ? root.dgpu.watts : 0
              range: root.dgpu ? root.dgpu.power_range : null
              unit: "W"; decimals: 1; limitWord: "limit"
              foreground: root.foreground
            }

            Repeater {
              model: root.snapshot && root.snapshot.fans ? root.snapshot.fans : []

              Gauge {
                required property var modelData
                width: column.width
                label: modelData.label + " fan"
                value: modelData.rpm
                range: modelData.range
                limitWord: "full tilt"
                foreground: root.foreground
              }
            }

            // ===== profile =====
            PanelSeparator { width: parent.width }
            PanelSectionHeader { text: "Performance profile"; foreground: root.foreground }

            OptionRow {
              width: parent.width
              options: root.textOptions(root.profileInfo ? root.profileInfo.choices : [])
              current: root.profileInfo ? root.profileInfo.current : null
              foreground: root.foreground
              onPicked: function (v) { root.send("/api/profile", { profile: v }) }
            }

            Text {
              visible: !!(root.profileInfo && root.profileInfo.ac_profile)
              width: parent.width
              text: "Switches automatically: " + (root.profileInfo ? root.profileInfo.ac_profile : "")
                + " on AC, " + (root.profileInfo ? root.profileInfo.battery_profile : "") + " on battery"
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              visible: !!(root.deck && root.deck.pending_reboot)
              width: parent.width
              text: "A change you made needs a reboot."
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            // ===== power =====
            PanelSeparator { width: parent.width }
            PanelSectionHeader { text: "Power & thermals"; foreground: root.foreground }

            Repeater {
              model: [
                { name: "ppt_pl1_spl", label: "CPU sustained (PL1)", hint: "long-run budget" },
                { name: "ppt_pl2_sppt", label: "CPU boost (PL2)", hint: "short bursts" },
                { name: "ppt_pl3_fppt", label: "CPU peak (PL3)", hint: "brief spikes" }
              ]

              LabelledSlider {
                required property var modelData
                readonly property var a: root.attr(modelData.name)
                width: column.width
                visible: !!a && a.min !== null && a.max !== null && a.min < a.max
                label: modelData.label
                hint: modelData.hint
                unit: " W"
                minimum: a ? a.min : 0
                maximum: a ? a.max : 1
                step: a && a.step ? a.step : 1
                value: a ? a.current : 0
                bar: null
                foreground: root.foreground
                onCommitted: function (v) {
                  root.send("/api/attribute", { name: modelData.name, value: Math.round(v) })
                }
              }
            }

            // ===== graphics =====
            PanelSeparator { width: parent.width }
            PanelSectionHeader { text: "Graphics"; foreground: root.foreground }

            OptionRow {
              width: parent.width
              visible: !!(root.graphics && root.graphics.supported)
              label: "GPU mode"
              hint: "switching ends your session"
              horizontal: false
              options: root.textOptions(root.graphics ? root.graphics.choices : [])
              current: root.graphics ? root.graphics.mode : null
              foreground: root.foreground
              onPicked: function (v) {
                if (root.graphics && v === root.graphics.mode) return
                root.send("/api/graphics", { mode: v })
              }
            }

            OptionRow {
              width: parent.width
              readonly property var a: root.attr("gpu_mux_mode")
              visible: !!a
              label: "Display MUX"
              hint: "needs a reboot"
              horizontal: false
              options: root.enumOptions(a, { 0: "Ultimate · dGPU drives display",
                                             1: "Optimus · hybrid" })
              current: a ? a.current : null
              foreground: root.foreground
              onPicked: function (v) { root.send("/api/attribute", { name: "gpu_mux_mode", value: v }) }
            }

            OptionRow {
              width: parent.width
              readonly property var a: root.attr("dgpu_disable")
              visible: !!a
              label: "Discrete GPU"
              options: root.enumOptions(a, { 0: "available", 1: "disabled" })
              current: a ? a.current : null
              foreground: root.foreground
              onPicked: function (v) { root.send("/api/attribute", { name: "dgpu_disable", value: v }) }
            }

            Repeater {
              model: [
                { name: "nv_tgp", label: "GPU total power", hint: "board limit", unit: " W" },
                { name: "nv_dynamic_boost", label: "GPU dynamic boost", hint: "watts from CPU", unit: " W" },
                { name: "nv_temp_target", label: "GPU temp limit", hint: "throttles here", unit: " °C" }
              ]

              LabelledSlider {
                required property var modelData
                readonly property var a: root.attr(modelData.name)
                width: column.width
                visible: !!a && a.min !== null && a.max !== null && a.min < a.max
                label: modelData.label
                hint: modelData.hint
                unit: modelData.unit
                minimum: a ? a.min : 0
                maximum: a ? a.max : 1
                step: a && a.step ? a.step : 1
                value: a ? a.current : 0
                foreground: root.foreground
                onCommitted: function (v) {
                  root.send("/api/attribute", { name: modelData.name, value: Math.round(v) })
                }
              }
            }

            // ===== battery =====
            PanelSeparator { width: parent.width }
            PanelSectionHeader { text: "Battery"; foreground: root.foreground }

            Gauge {
              width: parent.width
              visible: !!(root.battery && root.battery.present)
              label: "charge · " + (root.battery && root.battery.status ? root.battery.status : "")
              value: root.battery && root.battery.capacity !== null ? root.battery.capacity : 0
              range: ({ min: 0, warn: 100, crit: 100, max: 100, source: "hardware" })
              unit: "%"
              plain: true
              foreground: root.foreground
            }

            LabelledSlider {
              width: parent.width
              visible: !!(root.battery && root.battery.present)
              label: "Charge limit"
              hint: "60–80% is kinder to the pack on AC"
              unit: "%"
              minimum: 20; maximum: 100; step: 5
              value: root.battery && root.battery.charge_limit ? root.battery.charge_limit : 100
              foreground: root.foreground
              onCommitted: function (v) {
                root.send("/api/battery-limit", { percent: Math.round(v) })
              }
            }

            // ===== fan curves =====
            PanelSeparator { width: parent.width; visible: root.curves.length > 0 }
            PanelSectionHeader {
              text: "Fan curves"
              foreground: root.foreground
              visible: root.curves.length > 0
            }

            OptionRow {
              width: parent.width
              visible: root.curves.length > 0
              hint: "drag a point, then apply"
              options: {
                var out = []
                for (var i = 0; i < root.curves.length; i++)
                  out.push({ value: root.curves[i].fan, text: root.curves[i].fan + " fan" })
                return out
              }
              current: root.activeFan
              foreground: root.foreground
              onPicked: function (v) { root.activeFan = v; root.seedCurve() }
            }

            FanCurve {
              id: curveView
              width: parent.width
              visible: root.curves.length > 0
              points: root.draftCurve
              nowTemp: root.activeFan === "gpu"
                ? (root.dgpu && root.dgpu.celsius !== null ? root.dgpu.celsius : -1)
                : (root.cpu ? root.cpu.celsius : -1)
              foreground: root.foreground
            }

            Row {
              width: parent.width
              spacing: Style.spacing.sm
              visible: root.curves.length > 0

              Toggle {
                width: (parent.width - Style.spacing.sm) / 2
                label: "Apply curve"
                checked: false
                foreground: root.foreground
                onClicked: root.send("/api/fan-curve", {
                  profile: root.profileInfo ? root.profileInfo.current : "",
                  fan: root.activeFan,
                  points: root.draftCurve
                })
              }

              Toggle {
                width: (parent.width - Style.spacing.sm) / 2
                label: "Reset to default"
                checked: false
                foreground: root.foreground
                onClicked: root.send("/api/fan-curve-reset", {
                  profile: root.profileInfo ? root.profileInfo.current : ""
                })
              }
            }

            // ===== keyboard light =====
            PanelSeparator { width: parent.width }
            PanelSectionHeader { text: "Keyboard light"; foreground: root.foreground }

            OptionRow {
              width: parent.width
              label: "Brightness"
              options: root.textOptions(root.aura ? root.aura.brightness_choices : [])
              current: root.aura ? root.aura.brightness : null
              foreground: root.foreground
              onPicked: function (v) { root.send("/api/aura-brightness", { level: v }) }
            }

            OptionRow {
              width: parent.width
              label: "Effect"
              hint: "only the controls an effect accepts are sent"
              horizontal: false
              options: root.textOptions(root.aura ? root.aura.effects : [])
              current: root.auraEffect
              foreground: root.foreground
              onPicked: function (v) {
                root.auraEffect = v
                root.applyAura()
              }
            }

            Row {
              width: parent.width
              spacing: Style.spacing.sm

              Repeater {
                model: root.swatches

                Rectangle {
                  required property string modelData
                  width: Style.space(30)
                  height: Style.space(20)
                  radius: Style.cornerRadius
                  color: modelData
                  border.width: root.auraColour === modelData ? Math.max(2, Style.space(2)) : 1
                  border.color: root.auraColour === modelData ? root.foreground : root.dim

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.auraColour = modelData; root.applyAura() }
                  }
                }
              }
            }

            // ===== lid light bar =====
            PanelSeparator { width: parent.width; visible: !!(root.slash && root.slash.supported) }
            PanelSectionHeader {
              text: "Lid light bar"
              foreground: root.foreground
              visible: !!(root.slash && root.slash.supported)
            }

            Row {
              width: parent.width
              spacing: Style.spacing.sm
              visible: !!(root.slash && root.slash.supported)

              Toggle {
                width: (parent.width - Style.spacing.sm) / 2
                label: "Turn on"
                foreground: root.foreground
                onClicked: root.send("/api/slash", { enabled: true })
              }
              Toggle {
                width: (parent.width - Style.spacing.sm) / 2
                label: "Turn off"
                foreground: root.foreground
                onClicked: root.send("/api/slash", { enabled: false })
              }
            }

            OptionRow {
              width: parent.width
              visible: !!(root.slash && root.slash.supported)
              label: "Animation"
              hint: "\"loading\" is the classic ROG sweep"
              horizontal: false
              options: root.textOptions(root.slash ? root.slash.modes : [])
              current: null
              foreground: root.foreground
              onPicked: function (v) { root.send("/api/slash", { mode: v }) }
            }

            LabelledSlider {
              width: parent.width
              visible: !!(root.slash && root.slash.supported)
              label: "Light bar brightness"
              minimum: 0; maximum: 255; step: 5
              value: 128
              foreground: root.foreground
              onCommitted: function (v) { root.send("/api/slash", { brightness: Math.round(v) }) }
            }

            // ===== numpad =====
            PanelSeparator { width: parent.width; visible: !!(root.numpad && root.numpad.supported) }
            PanelSectionHeader {
              text: "Trackpad numpad"
              foreground: root.foreground
              visible: !!(root.numpad && root.numpad.supported)
            }

            Toggle {
              width: parent.width
              visible: !!(root.numpad && root.numpad.supported)
              label: "NumberPad lit"
              description: "no need for the corner gesture"
              checked: !!(root.numpad && root.numpad.enabled)
              foreground: root.foreground
              onClicked: root.send("/api/numpad", { enabled: !(root.numpad && root.numpad.enabled) })
            }

            LabelledSlider {
              width: parent.width
              visible: !!(root.numpad && root.numpad.supported)
              label: "Auto-off after idle"
              hint: "0 disables it"
              unit: " s"
              minimum: 0; maximum: 120; step: 10
              value: root.numpad ? Number(root.numpad.inactivity_timeout) : 120
              foreground: root.foreground
              onCommitted: function (v) {
                root.send("/api/numpad", { disable_due_inactivity_time: Math.round(v) })
              }
            }

            // ===== ripple =====
            PanelSeparator { width: parent.width; visible: !!(root.ripple && root.ripple.supported) }
            PanelSectionHeader {
              text: "Keyboard ripple"
              foreground: root.foreground
              visible: !!(root.ripple && root.ripple.supported)
            }

            Toggle {
              width: parent.width
              visible: !!(root.ripple && root.ripple.supported)
              label: "Reactive ripple"
              description: "a wave from each key you press"
              checked: !!(root.ripple && root.ripple.active)
              foreground: root.foreground
              onClicked: root.send("/api/ripple", { active: !(root.ripple && root.ripple.active) })
            }

            Toggle {
              width: parent.width
              visible: !!(root.ripple && root.ripple.supported)
              label: "Start at login"
              checked: !!(root.ripple && root.ripple.enabled)
              foreground: root.foreground
              onClicked: root.send("/api/ripple", { enabled: !(root.ripple && root.ripple.enabled) })
            }

            Row {
              width: parent.width
              spacing: Style.spacing.sm
              visible: !!(root.ripple && root.ripple.supported)

              Repeater {
                model: root.swatches

                Rectangle {
                  required property string modelData
                  width: Style.space(30)
                  height: Style.space(20)
                  radius: Style.cornerRadius
                  color: modelData
                  border.width: root.ripple && root.ripple.settings
                    && root.ripple.settings.colour === modelData ? Math.max(2, Style.space(2)) : 1
                  border.color: root.ripple && root.ripple.settings
                    && root.ripple.settings.colour === modelData ? root.foreground : root.dim

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.send("/api/ripple", { colour: modelData })
                  }
                }
              }
            }

            Repeater {
              model: [
                { key: "brightness", label: "Max brightness", step: 0.05, decimals: 2 },
                { key: "speed", label: "Wave speed", step: 0.5, decimals: 1 },
                { key: "decay", label: "Fade time", step: 0.05, decimals: 2, unit: " s" },
                { key: "base", label: "Idle glow", step: 0.01, decimals: 2 },
                { key: "steps", label: "Trail bands", step: 1, decimals: 0, hint: "0 = smooth" }
              ]

              LabelledSlider {
                required property var modelData
                readonly property var lim: root.ripple && root.ripple.limits
                  ? root.ripple.limits[modelData.key] : null
                width: column.width
                visible: !!(root.ripple && root.ripple.supported && lim)
                label: modelData.label
                hint: modelData.hint ? modelData.hint : ""
                unit: modelData.unit ? modelData.unit : ""
                decimals: modelData.decimals
                minimum: lim ? lim[0] : 0
                maximum: lim ? lim[1] : 1
                step: modelData.step
                value: root.ripple && root.ripple.settings
                  ? root.ripple.settings[modelData.key] : 0
                foreground: root.foreground
                onCommitted: function (v) {
                  var patch = {}
                  patch[modelData.key] = v
                  root.send("/api/ripple", patch)
                }
              }
            }

            // ===== system =====
            PanelSeparator { width: parent.width }
            PanelSectionHeader { text: "System"; foreground: root.foreground }

            Repeater {
              model: [
                { name: "panel_overdrive", label: "Panel overdrive",
                  labels: { 0: "off", 1: "on · faster pixels" } },
                { name: "screen_auto_brightness", label: "Auto brightness",
                  labels: { 0: "off", 1: "on" } },
                { name: "boot_sound", label: "Boot sound",
                  labels: { 0: "silent", 1: "ROG chime" } }
              ]

              OptionRow {
                required property var modelData
                readonly property var a: root.attr(modelData.name)
                width: column.width
                visible: !!a
                label: modelData.label
                options: root.enumOptions(a, modelData.labels)
                current: a ? a.current : null
                foreground: root.foreground
                onPicked: function (v) {
                  root.send("/api/attribute", { name: modelData.name, value: v })
                }
              }
            }
          }
        }

        // ---- footer ----
        Text {
          id: footer
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          text: "Esc closes · scroll for more"
          color: Qt.darker(root.foreground, 1.9)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption * 0.9
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }

  // Aura effects only accept certain arguments; asusctl errors on the rest,
  // so send exactly what this effect supports.
  function applyAura() {
    if (auraEffect === "") return
    var accepted = aura && aura.effect_args ? aura.effect_args[auraEffect] : null
    var body = { effect: auraEffect }
    if (accepted) {
      for (var i = 0; i < accepted.length; i++) {
        var name = accepted[i]
        if (name === "colour") body.colour = auraColour
        else if (name === "colour2") body.colour2 = "#0000ff"
        else if (name === "speed") body.speed = "med"
        else if (name === "direction") body.direction = "left"
      }
    }
    send("/api/aura-effect", body)
  }
}
