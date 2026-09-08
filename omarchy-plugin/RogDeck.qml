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
  // supergfxd answers a mode change with things like "A reboot is required to
  // complete the mode change". Showing it is the difference between a switch
  // that looks broken and one that is simply waiting for a restart.
  property string gfxNotice: ""
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
  readonly property var graphics: deck && deck.graphics ? deck.graphics : null
  readonly property var numpad: deck && deck.numpad ? deck.numpad : null
  readonly property var lighting: deck && deck.lighting ? deck.lighting : null
  readonly property var light: lighting ? lighting.settings : null
  readonly property var curves:
    deck && deck.fan_curves && deck.fan_curves.available ? deck.fan_curves.curves : []
  readonly property var cpu: Api.warmestCpu(snapshot)
  readonly property var dgpu: snapshot && snapshot.dgpu ? snapshot.dgpu : null

  // Saturated hues: the keyboard LEDs are full RGB, and the previous set
  // borrowed muted UI colours that looked washed out on the board.
  // ---- explanations ----
  // Written for someone who wants to know what a setting does and when to
  // reach for it, not just what it is called.
  readonly property string tipSensors:
    "Live readings. Each bar runs from idle to that part's own ceiling: the "
    + "temperature it throttles at, a fan's top speed, or a power limit.\n\n"
    + "Green is fine. Amber is warm but working. Red means you are at the "
    + "limit and the hardware will start slowing itself down to cope.\n\n"
    + "A ceiling marked (est) is our estimate, because that part does not "
    + "publish one."

  readonly property string tipProfile:
    "The master switch. Each profile carries its own CPU power limits and fan "
    + "curves, so changing it moves several settings below at once.\n\n"
    + "Quiet — least power, slowest fans. Best for battery, reading, video.\n"
    + "Balanced — the everyday setting.\n"
    + "Performance — most power, fastest fans. For games, compiling and "
    + "rendering; noticeably louder and hotter.\n\n"
    + "asusd also remembers a profile per power source, which is why this can "
    + "change on its own when you plug in or unplug."

  readonly property string tipPower:
    "How many watts the CPU may draw, over three timescales.\n\n"
    + "PL1 (sustained) — the long-run budget. This is the one that decides "
    + "speed in anything lasting more than a minute.\n"
    + "PL2 (boost) — a higher ceiling for short bursts, seconds at a time.\n"
    + "PL3 (peak) — a brief spike, well under a second.\n\n"
    + "Lowering them makes the laptop cooler, quieter and longer-lasting on "
    + "battery, at the cost of speed. Raising them does the reverse and the "
    + "fans will follow. \"Recommended\" is your firmware's own default for "
    + "the profile you are in, so it changes when the profile does."

  readonly property string tipGraphics:
    "Which GPU drives your screen, and how much power it gets.\n\n"
    + "GPU mode — Hybrid lets the integrated GPU draw the desktop and wakes "
    + "the NVIDIA card only for demanding apps; best battery life and the "
    + "usual choice. Integrated powers the NVIDIA card off entirely. "
    + "AsusMuxDgpu gives everything to the NVIDIA card for maximum speed. "
    + "Switching restarts your graphical session, so save first.\n\n"
    + "The MUX (whether the panel is wired to the NVIDIA card directly) is "
    + "part of GPU mode above: AsusMuxDgpu is that wiring. It is a hardware "
    + "switch, so it needs a reboot.\n\n"
    + "Note — whether the panel is wired to the NVIDIA card directly "
    + "(Ultimate: a few percent more performance and lower latency in games, "
    + "but the iGPU can no longer save power, so battery life drops) or "
    + "through the iGPU (Optimus: better battery). It is a hardware switch, "
    + "so it needs a reboot.\n\n"
    + "GPU total power — the wattage budget for the card. The single biggest "
    + "lever on GPU speed, and on heat.\n\n"
    + "GPU dynamic boost — lets the laptop shift watts between CPU and GPU "
    + "as needed. In a game the GPU usually wants them more, so leaving this "
    + "high tends to give extra frames for free.\n\n"
    + "GPU temp limit — where the card starts slowing itself to stay safe. "
    + "Lower is cooler and quieter but caps performance sooner."

  readonly property string tipFans:
    "A fan curve maps temperature to fan speed: at each point, \"when the "
    + "chip is this hot, spin this fast\". Drag a point, then apply — nothing "
    + "is written until you do.\n\n"
    + "Each profile has its own curves, so edits here only affect the profile "
    + "you are in. Raising the curve keeps temperatures lower at the cost of "
    + "noise; lowering it is quieter but can let the chip throttle.\n\n"
    + "The dashed green line is the current temperature, so you can see which "
    + "part of the curve you actually live on."

  readonly property string tipBattery:
    "Charge limit stops charging below full. Lithium cells age fastest when "
    + "held at 100%, so if the laptop mostly sits on mains, 60–80% will "
    + "noticeably extend its life. Set it back to 100% before travelling."

  readonly property string tipLighting:
    "One behaviour at a time.\n\n"
    + "Off — backlight dark.\n"
    + "Built-in effect — a pattern the keyboard firmware runs by itself.\n"
    + "Reactive ripple — our effect, a wave from each key you press.\n\n"
    + "Brightness is the keyboard's own level, which its Fn keys also change. "
    + "It scales whatever is running."

  readonly property string tipNumpad:
    "The illuminated number pad drawn on the trackpad. Normally you hold the "
    + "top-right corner for a second to toggle it; this is the same switch "
    + "without the gesture.\n\n"
    + "Auto-off dims it again after a spell of no use, so it does not sit lit "
    + "all evening."

  readonly property string tipSystem:
    "Panel overdrive speeds up pixel transitions, which cuts ghosting in fast "
    + "motion but can add slight overshoot around moving edges.\n\n"
    + "Auto brightness uses the ambient light sensor.\n\n"
    + "Boot sound plays the ROG chime at power-on."

  // Type-to-filter. Deliberately not a focusable TextField: the panel catches
  // keystrokes itself and the field is a read-out, so nothing ever has to be
  // clicked into and no control can steal the keys.
  property string filter: ""

  function matches(haystack) {
    if (filter === "") return true
    var hay = String(haystack).toLowerCase()
    var terms = filter.toLowerCase().split(/\s+/)
    for (var i = 0; i < terms.length; i++) {
      if (terms[i] !== "" && hay.indexOf(terms[i]) === -1) return false
    }
    return true
  }

  // Explanation tip state. The tip is drawn in the window's top layer rather
  // than beside each icon, because the scrolling container clips its children.
  property string tipText: ""
  property real tipX: 0
  property real tipY: 0

  function showTip(text, item) {
    if (!item) return
    var p = item.mapToItem(card, 0, item.height)
    tipX = p.x
    tipY = p.y + Style.spacing.sm
    tipText = text
  }

  function hideTip() { tipText = "" }

  readonly property var swatches: [
    "#ff0000", "#ff6a00", "#ffd400", "#00ff3c",
    "#00e5ff", "#0066ff", "#c400ff", "#ffffff"
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

        // Escape clears a filter first and only closes the app once there is
        // nothing left to clear, so a stray search never costs you the window.
        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Escape) {
            if (root.filter !== "") root.filter = ""
            else root.dismiss()
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_Backspace) {
            root.filter = root.filter.slice(0, -1)
            event.accepted = true
            return
          }
          // Printable characters only; modifiers and function keys fall
          // through so they keep working.
          if (event.text.length === 1 && event.text >= " " && event.text !== "\u007f") {
            root.filter += event.text
            event.accepted = true
          }
        }

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

          // Search read-out. Reads as a prompt rather than an input, because
          // it is never focused - you just type.
          Row {
            width: parent.width
            spacing: Style.spacing.sm
            topPadding: Style.spacing.xxs

            Text {
              text: "search"
              color: Qt.darker(root.foreground, 1.6)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Rectangle {
              width: Math.max(Style.space(160), query.implicitWidth + Style.spacing.lg)
              height: query.implicitHeight + Style.spacing.sm
              radius: Style.cornerRadius
              color: root.filter === ""
                ? Qt.alpha(root.foreground, 0.06)
                : Qt.alpha(Color.accent, 0.14)
              border.width: 1
              border.color: root.filter === ""
                ? Qt.alpha(root.foreground, 0.20) : Qt.alpha(Color.accent, 0.7)

              Behavior on color { ColorAnimation { duration: 130 } }
              Behavior on border.color { ColorAnimation { duration: 130 } }

              Text {
                id: query
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                text: root.filter === "" ? "type to filter" : root.filter
                color: root.filter === ""
                  ? Qt.darker(root.foreground, 1.9) : root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              // Blinking caret, so it is obvious typing goes here even though
              // the field cannot be focused.
              Rectangle {
                visible: root.filter !== ""
                anchors.left: query.right
                anchors.leftMargin: 1
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(1, Style.space(1))
                height: query.implicitHeight * 0.85
                color: Color.accent
                SequentialAnimation on opacity {
                  running: root.filter !== ""
                  loops: Animation.Infinite
                  NumberAnimation { to: 0.15; duration: 480 }
                  NumberAnimation { to: 1.0; duration: 480 }
                }
              }
            }

            Text {
              visible: root.filter !== ""
              text: "Esc clears"
              color: Qt.darker(root.foreground, 1.8)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
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

              // --- Sensors ---
              Column {
                width: parent.width
                spacing: Style.spacing.md
                visible: root.matches("Sensors temperature temp heat thermal fan rpm cpu gpu power draw watts ssd")
                SectionTitle { text: "Sensors"; info: root.tipSensors; host: root; foreground: root.foreground }

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
              }

              // --- Performance profile ---
              Column {
                width: parent.width
                spacing: Style.spacing.md
                visible: root.matches("Performance profile profile quiet balanced performance mode power preset")
                PanelSeparator { width: parent.width }
                SectionTitle { text: "Performance profile"; info: root.tipProfile; host: root; foreground: root.foreground }

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
              }

              // --- Power & thermals ---
              Column {
                width: parent.width
                spacing: Style.spacing.md
                visible: root.matches("Power & thermals ppt pl1 pl2 pl3 watts cpu power limit sustained boost peak thermal")
                PanelSeparator { width: parent.width }
                SectionTitle { text: "Power & thermals"; info: root.tipPower; host: root; foreground: root.foreground }

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
                    recommended: a && a.default !== null && a.default !== undefined
                      ? a.default : NaN
                    foreground: root.foreground
                    onCommitted: function (v) {
                      root.send("/api/attribute", { name: modelData.name, value: Math.round(v) })
              }
                  }
                }
              }

              // --- Graphics ---
              Column {
                width: parent.width
                spacing: Style.spacing.md
                visible: root.matches("Graphics gpu mux optimus ultimate dgpu nvidia tgp dynamic boost temp limit supergfx display")
                PanelSeparator { width: parent.width }
                SectionTitle { text: "Graphics"; info: root.tipGraphics; host: root; foreground: root.foreground }

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
                    Api.post("/api/graphics", { mode: v }, function (data, err) {
                      root.errorText = err === null ? "" : err
                      root.gfxNotice = (data && data.notice) ? data.notice : ""
                      root.refresh()
                    })
                  }
                }

                Text {
                  visible: root.gfxNotice !== ""
                  width: parent.width
                  wrapMode: Text.WordWrap
                  text: root.gfxNotice
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
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
                    recommended: a && a.default !== null && a.default !== undefined
                      ? a.default : NaN
                    foreground: root.foreground
                    onCommitted: function (v) {
                      root.send("/api/attribute", { name: modelData.name, value: Math.round(v) })
              }
                  }
                }
              }

              // --- Battery ---
              Column {
                width: parent.width
                spacing: Style.spacing.md
                visible: root.matches("Battery battery charge limit longevity health mains")
                PanelSeparator { width: parent.width }
                SectionTitle { text: "Battery"; info: root.tipBattery; host: root; foreground: root.foreground }

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
            }

            // ================= RIGHT: things you act on =================
            Column {
              id: rightColumn
              width: (parent.width - Style.spacing.xl) / 2
              spacing: Style.spacing.md

              // --- Fan curves ---
              Column {
                width: parent.width
                spacing: Style.spacing.md
                visible: root.matches("Fan curves fan curve rpm cooling noise quiet temperature")
                SectionTitle {
                  text: "Fan curves"
                  info: root.tipFans
                  host: root
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
              }
              // --- Keyboard lighting ---
              Column {
                width: parent.width
                spacing: Style.spacing.md
                visible: root.matches("Keyboard lighting keyboard light lighting aura rgb brightness effect ripple colour color backlight")
                PanelSeparator { width: parent.width }
                SectionTitle { text: "Keyboard lighting"; info: root.tipLighting; host: root; foreground: root.foreground }

                RadioGroup {
                  width: parent.width
                  visible: !!root.light
                  hint: "one behaviour at a time"
                  // The ripple mode is only offered when its unit is actually
                  // installed; it can be disengaged deliberately, and offering
                  // a mode that cannot start is worse than not offering it.
                  options: {
                    var out = [
                      { value: "off", text: "Off", description: "backlight dark" },
                      { value: "effect", text: "Built-in effect",
                        description: "a firmware Aura pattern" }
                    ]
                    if (root.lighting && root.lighting.ripple_available)
                      out.push({ value: "ripple", text: "Reactive ripple",
                                 description: "a wave from each key you press" })
                    return out
                  }
                  current: root.light ? root.light.mode : null
                  foreground: root.foreground
                  onPicked: function (v) { root.sendLight({ mode: v }) }
                }

                RadioGroup {
                  width: parent.width
                  visible: !!root.light && root.light.mode !== "off"
                  label: "Brightness"
                  hint: "the keyboard's own Fn keys change this too"
                  options: root.textOptions(
                    (root.lighting ? root.lighting.brightness_choices : [])
                      .filter(function (b) { return b !== "off" }))
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
                    { key: "speed", label: "Wave speed", step: 0.5, decimals: 1 },
                    { key: "decay", label: "Fade time", step: 0.05, decimals: 2, unit: " s" }
                  ]

                  LabelledSlider {
                    required property var modelData
                    readonly property var lim: modelData && root.lighting
                      && root.lighting.ripple_limits
                      ? root.lighting.ripple_limits[modelData.key] : null
                    width: rightColumn.width
                    visible: !!(root.light && root.light.mode === "ripple" && lim)
                    label: modelData.label
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
                  text: "Brightness follows the keyboard's own level, so the Fn "
                    + "brightness keys scale the ripple with it."
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
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

                // ---------------- numpad ----------------
              }
              // --- Trackpad numpad ---
              Column {
                width: parent.width
                spacing: Style.spacing.md
                visible: root.matches("Trackpad numpad numpad trackpad touchpad keypad numbers numlock")
                PanelSeparator { width: parent.width; visible: !!(root.numpad && root.numpad.supported) }
                SectionTitle {
                  text: "Trackpad numpad"
                  info: root.tipNumpad
                  host: root
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
              }
              // --- System ---
              Column {
                width: parent.width
                spacing: Style.spacing.md
                visible: root.matches("System panel overdrive auto brightness boot sound chime display system")
                PanelSeparator { width: parent.width }
                SectionTitle { text: "System"; info: root.tipSystem; host: root; foreground: root.foreground }

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
        }

        // ---- explanation tip ----
        BorderSurface {
          id: tip
          visible: root.tipText !== ""
          opacity: root.tipText !== "" ? 1 : 0
          width: Math.min(Style.space(380), card.width - Style.spacing.xl)
          height: tipBody.implicitHeight + Style.spacing.lg * 2
          // Keep it on screen: nudge left/up when it would overhang.
          x: Math.max(Style.spacing.sm,
               Math.min(root.tipX, card.width - width - Style.spacing.sm))
          y: Math.max(Style.spacing.sm,
               Math.min(root.tipY, card.height - height - Style.spacing.sm))
          z: 100
          color: Color.tooltip.background
          borderSpec: Border.surfaceSpec("tooltip", "border", Color.tooltip.border,
                                         Math.max(1, Style.space(1)))
          radius: Style.cornerRadius

          Behavior on opacity { NumberAnimation { duration: 130 } }
          // A small rise on appear, which reads as the tip coming forward.
          transform: Translate { y: root.tipText !== "" ? 0 : Style.space(6)
            Behavior on y { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
          }

          Text {
            id: tipBody
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.spacing.lg
            text: root.tipText
            color: Color.tooltip.text
            wrapMode: Text.WordWrap
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            lineHeight: 1.35
          }
        }

        Text {
          id: footer
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          text: "Type to filter · Esc clears, then closes · drag a slider to change it"
          color: Qt.darker(root.foreground, 1.9)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption * 0.9
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }
}
