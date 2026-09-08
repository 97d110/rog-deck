import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Api.js" as Api

// ROG Deck as an Omarchy app: a real toplevel window, so Hyprland tiles it,
// floats it and moves it between workspaces like any other application - the
// layer-shell overlay it used to be could do none of that, and it stole the
// keyboard while open.
//
// It shares the [menu] surface tokens, so a theme that styles the command
// palette styles this too, and it is assembled from the shell's own
// components (PanelSectionHeader, PanelSeparator, Button) plus local
// RadioGroup/DragSlider controls.
//
// Summon:  omarchy-shell shell summon rog-deck '{}'
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
  property bool curveDirty: false

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
  readonly property var slash: deck && deck.slash ? deck.slash : null
  readonly property var graphics: deck && deck.graphics ? deck.graphics : null
  readonly property var numpad: deck && deck.numpad ? deck.numpad : null
  readonly property var lighting: deck && deck.lighting ? deck.lighting : null
  readonly property var light: lighting ? lighting.settings : null
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

  function textOptions(values, describe) {
    var out = []
    for (var i = 0; i < (values || []).length; i++) {
      var v = values[i]
      out.push({
        value: v,
        text: String(v).replace(/-/g, " "),
        description: describe ? describe(v) : undefined
      })
    }
    return out
  }

  function effectAccepts(name) {
    if (!lighting || !light) return false
    var args = lighting.effect_args ? lighting.effect_args[light.effect] : null
    if (!args) return false
    for (var i = 0; i < args.length; i++) if (args[i] === name) return true
    return false
  }

  function refresh() {
    Api.get("/api/state", function (data, err) {
      root.errorText = err === null ? "" : err
      if (!data) return
      root.deck = data
      if (!root.curveDirty) root.seedCurve()
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

  // Lighting is one atomic call: mode, effect, colour, speed and brightness go
  // together so the hardware never ends up disagreeing with the controls.
  function sendLight(patch) { send("/api/lighting", patch) }

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

  FloatingWindow {
    id: window
    title: "ROG Deck"
    color: root.background
    implicitWidth: 1180
    implicitHeight: 780
    minimumSize: Qt.size(640, 480)
    visible: root.opened

    // Closing from the window frame has to tell the shell host, or it keeps
    // thinking the panel is open and the next summon toggles it shut.
    onVisibleChanged: {
      if (!visible && root.opened && root.shell && typeof root.shell.hide === "function")
        root.shell.hide("rog-deck")
    }

    FocusScope {
      id: card
      anchors.fill: parent
      focus: true

      Item {
        id: keyCatcher
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding
        focus: true
        Keys.onEscapePressed: root.dismiss()

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
            width: parent.width
            elide: Text.ElideRight
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
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
        }

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
          contentHeight: columns.implicitHeight
          boundsBehavior: Flickable.StopAtBounds

          // Two columns: a single stack wasted most of the panel width and
          // pushed everything below the fold. Readings and ranges on the
          // left, the things you act on on the right.
          Row {
            id: columns
            width: body.width - Style.spacing.md
            spacing: Style.spacing.xl

            // ================= LEFT: readings and ranges =================
            Column {
              id: leftColumn
              width: (parent.width - Style.spacing.xl) / 2
              spacing: Style.spacing.md

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
                  width: leftColumn.width
                  label: modelData.label + " fan"
                  value: modelData.rpm
                  range: modelData.range
                  limitWord: "full tilt"
                  foreground: root.foreground
                }
              }

              PanelSeparator { width: parent.width }
              PanelSectionHeader { text: "Performance profile"; foreground: root.foreground }

              RadioGroup {
                width: parent.width
                options: root.textOptions(root.profileInfo ? root.profileInfo.choices : [])
                current: root.profileInfo ? root.profileInfo.current : null
                foreground: root.foreground
                onPicked: function (v) { root.send("/api/profile", { profile: v }) }
              }

              Text {
                visible: !!(root.profileInfo && root.profileInfo.ac_profile)
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Switches automatically: " + (root.profileInfo ? root.profileInfo.ac_profile : "")
                  + " on AC, " + (root.profileInfo ? root.profileInfo.battery_profile : "") + " on battery"
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Text {
                visible: !!(root.deck && root.deck.pending_reboot)
                width: parent.width
                text: "A change you made needs a reboot."
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

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
                  readonly property var a: modelData ? root.attr(modelData.name) : null
                  width: leftColumn.width
                  visible: !!a && a.min !== null && a.max !== null && a.min < a.max
                  label: modelData.label
                  hint: modelData.hint
                  unit: " W"
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

              PanelSeparator { width: parent.width }
              PanelSectionHeader { text: "Graphics"; foreground: root.foreground }

              RadioGroup {
                width: parent.width
                visible: !!(root.graphics && root.graphics.supported)
                label: "GPU mode"
                hint: "switching ends your session"
                options: root.textOptions(root.graphics ? root.graphics.choices : [])
                current: root.graphics ? root.graphics.mode : null
                foreground: root.foreground
                onPicked: function (v) {
                  if (root.graphics && v === root.graphics.mode) return
                  root.send("/api/graphics", { mode: v })
                }
              }

              RadioGroup {
                width: parent.width
                readonly property var a: root.attr("gpu_mux_mode")
                visible: !!a
                label: "Display MUX"
                hint: "needs a reboot"
                options: root.enumOptions(a, { 0: "Ultimate — dGPU drives the display",
                                               1: "Optimus — hybrid" })
                current: a ? a.current : null
                foreground: root.foreground
                onPicked: function (v) { root.send("/api/attribute", { name: "gpu_mux_mode", value: v }) }
              }

              RadioGroup {
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
                  readonly property var a: modelData ? root.attr(modelData.name) : null
                  width: leftColumn.width
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
            }

            // ================= RIGHT: things you act on =================
            Column {
              id: rightColumn
              width: (parent.width - Style.spacing.xl) / 2
              spacing: Style.spacing.md

              PanelSectionHeader {
                text: "Fan curves"
                foreground: root.foreground
                visible: root.curves.length > 0
              }

              RadioGroup {
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
                onPicked: function (v) {
                  root.activeFan = v
                  root.curveDirty = false
                  root.seedCurve()
                }
              }

              FanCurve {
                width: parent.width
                visible: root.curves.length > 0
                points: root.draftCurve
                nowTemp: root.activeFan === "gpu"
                  ? (root.dgpu && root.dgpu.celsius !== null ? root.dgpu.celsius : -1)
                  : (root.cpu ? root.cpu.celsius : -1)
                foreground: root.foreground
                onEdited: root.curveDirty = true
              }

              // Buttons, not toggles: these are actions, and a toggle implied
              // a stored state that does not exist.
              Row {
                width: parent.width
                spacing: Style.spacing.sm
                visible: root.curves.length > 0

                Button {
                  text: root.curveDirty ? "Apply changes" : "Apply curve"
                  bordered: true
                  foreground: root.curveDirty ? Color.accent : root.foreground
                  onClicked: {
                    root.curveDirty = false
                    root.send("/api/fan-curve", {
                      profile: root.profileInfo ? root.profileInfo.current : "",
                      fan: root.activeFan,
                      points: root.draftCurve
                    })
                  }
                }

                Button {
                  text: "Reset to firmware default"
                  bordered: true
                  foreground: root.foreground
                  onClicked: {
                    root.curveDirty = false
                    root.send("/api/fan-curve-reset", {
                      profile: root.profileInfo ? root.profileInfo.current : ""
                    })
                  }
                }
              }

              Text {
                visible: root.curveDirty
                width: parent.width
                text: "Unapplied changes — nothing is written until you apply."
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              // ---------------- keyboard lighting ----------------
              PanelSeparator { width: parent.width }
              PanelSectionHeader { text: "Keyboard lighting"; foreground: root.foreground }

              RadioGroup {
                width: parent.width
                visible: !!root.light
                hint: "one behaviour at a time"
                options: [
                  { value: "off", text: "Off", description: "backlight dark" },
                  { value: "effect", text: "Built-in effect",
                    description: "a firmware Aura pattern" },
                  { value: "ripple", text: "Reactive ripple",
                    description: "a wave from each key you press" }
                ]
                current: root.light ? root.light.mode : null
                foreground: root.foreground
                onPicked: function (v) { root.sendLight({ mode: v }) }
              }

              RadioGroup {
                width: parent.width
                visible: !!root.light && root.light.mode !== "off"
                label: "Brightness"
                options: root.textOptions(root.lighting ? root.lighting.brightness_choices : [])
                current: root.light ? root.light.brightness : null
                foreground: root.foreground
                onPicked: function (v) { root.sendLight({ brightness: v }) }
              }

              Text {
                visible: !!root.lighting && root.light && root.light.mode !== "off"
                  && root.lighting.hardware_brightness === "off"
                width: parent.width
                wrapMode: Text.WordWrap
                text: "The hardware reports the backlight as off and is not accepting "
                  + "brightness changes. Try the keyboard-backlight key, or mains power."
                color: Color.urgent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              RadioGroup {
                width: parent.width
                visible: !!root.light && root.light.mode === "effect"
                label: "Effect"
                options: root.textOptions(root.lighting ? root.lighting.effects : [])
                current: root.light ? root.light.effect : null
                foreground: root.foreground
                onPicked: function (v) { root.sendLight({ effect: v }) }
              }

              // Only the controls this effect actually accepts are shown -
              // asusctl hard-errors on the rest, and hiding them is why the
              // parameters no longer fight each other.
              ColourRow {
                width: parent.width
                visible: !!root.light && root.light.mode === "effect" && root.effectAccepts("colour")
                label: "Colour"
                swatches: root.swatches
                current: root.light ? root.light.colour : ""
                foreground: root.foreground
                onPicked: function (c) { root.sendLight({ colour: c }) }
              }

              ColourRow {
                width: parent.width
                visible: !!root.light && root.light.mode === "effect" && root.effectAccepts("colour2")
                label: "Second colour"
                swatches: root.swatches
                current: root.light ? root.light.colour2 : ""
                foreground: root.foreground
                onPicked: function (c) { root.sendLight({ colour2: c }) }
              }

              RadioGroup {
                width: parent.width
                visible: !!root.light && root.light.mode === "effect" && root.effectAccepts("speed")
                label: "Speed"
                options: root.textOptions(root.lighting ? root.lighting.speeds : [])
                current: root.light ? root.light.speed : null
                foreground: root.foreground
                onPicked: function (v) { root.sendLight({ speed: v }) }
              }

              RadioGroup {
                width: parent.width
                visible: !!root.light && root.light.mode === "effect" && root.effectAccepts("direction")
                label: "Direction"
                options: root.textOptions(root.lighting ? root.lighting.directions : [])
                current: root.light ? root.light.direction : null
                foreground: root.foreground
                onPicked: function (v) { root.sendLight({ direction: v }) }
              }

              // ---- ripple parameters, only while that mode is chosen ----
              ColourRow {
                width: parent.width
                visible: !!root.light && root.light.mode === "ripple"
                label: "Ripple colour"
                swatches: root.swatches
                current: root.lighting && root.lighting.ripple ? root.lighting.ripple.colour : ""
                foreground: root.foreground
                onPicked: function (c) { root.send("/api/ripple", { colour: c }) }
              }

              Repeater {
                model: [
                  { key: "brightness", label: "Max brightness", step: 0.05, decimals: 2 },
                  { key: "speed", label: "Wave speed", step: 0.5, decimals: 1 },
                  { key: "decay", label: "Fade time", step: 0.05, decimals: 2, unit: " s" },
                  { key: "steps", label: "Trail bands", step: 1, decimals: 0, hint: "0 = smooth" }
                ]

                LabelledSlider {
                  required property var modelData
                  readonly property var lim: modelData && root.lighting
                    && root.lighting.ripple_limits
                    ? root.lighting.ripple_limits[modelData.key] : null
                  width: rightColumn.width
                  visible: !!(root.light && root.light.mode === "ripple" && lim)
                  label: modelData.label
                  hint: modelData.hint ? modelData.hint : ""
                  unit: modelData.unit ? modelData.unit : ""
                  decimals: modelData.decimals
                  minimum: lim ? lim[0] : 0
                  maximum: lim ? lim[1] : 1
                  step: modelData.step
                  value: root.lighting && root.lighting.ripple
                    ? root.lighting.ripple[modelData.key] : 0
                  foreground: root.foreground
                  onCommitted: function (v) {
                    var patch = {}
                    patch[modelData.key] = v
                    root.send("/api/ripple", patch)
                  }
                }
              }

              Text {
                visible: !!root.light && root.light.mode === "ripple"
                width: parent.width
                wrapMode: Text.WordWrap
                text: "The ripple reads key events to know where each wave starts. "
                  + "Only the key position is used."
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              // ---------------- lid light bar ----------------
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

                Button {
                  text: "Turn on"
                  bordered: true
                  foreground: root.foreground
                  onClicked: root.send("/api/slash", { enabled: true })
                }
                Button {
                  text: "Turn off"
                  bordered: true
                  foreground: root.foreground
                  onClicked: root.send("/api/slash", { enabled: false })
                }
              }

              RadioGroup {
                width: parent.width
                visible: !!(root.slash && root.slash.supported)
                label: "Animation"
                hint: "asusctl cannot read this back, so picking one sends it"
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

              // ---------------- numpad ----------------
              PanelSeparator { width: parent.width; visible: !!(root.numpad && root.numpad.supported) }
              PanelSectionHeader {
                text: "Trackpad numpad"
                foreground: root.foreground
                visible: !!(root.numpad && root.numpad.supported)
              }

              RadioGroup {
                width: parent.width
                visible: !!(root.numpad && root.numpad.supported)
                options: [
                  { value: "on", text: "Lit", description: "no need for the corner gesture" },
                  { value: "off", text: "Dark" }
                ]
                current: root.numpad && root.numpad.enabled ? "on" : "off"
                foreground: root.foreground
                onPicked: function (v) { root.send("/api/numpad", { enabled: v === "on" }) }
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

              // ---------------- system ----------------
              PanelSeparator { width: parent.width }
              PanelSectionHeader { text: "System"; foreground: root.foreground }

              Repeater {
                model: [
                  { name: "panel_overdrive", label: "Panel overdrive",
                    labels: { 0: "off", 1: "on — faster pixels" } },
                  { name: "screen_auto_brightness", label: "Auto brightness",
                    labels: { 0: "off", 1: "on" } },
                  { name: "boot_sound", label: "Boot sound",
                    labels: { 0: "silent", 1: "ROG chime" } }
                ]

                RadioGroup {
                  required property var modelData
                  readonly property var a: modelData ? root.attr(modelData.name) : null
                  width: rightColumn.width
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
        }

        Text {
          id: footer
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          text: "Esc closes · drag a slider to change it"
          color: Qt.darker(root.foreground, 1.9)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption * 0.9
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }
}
