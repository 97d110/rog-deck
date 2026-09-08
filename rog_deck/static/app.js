/* ROG Deck front-end. No framework, no build step - it ships as-is. */

const $ = (sel) => document.querySelector(sel);
const el = (tag, cls, text) => {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined) node.textContent = text;
  return node;
};

let STATE = null;
let activeFan = "cpu";
let draftCurves = {};   // fan -> points, holds unsaved drags
let latestSnapshot = null;

/* ---------------- transport ---------------- */

async function api(path, body) {
  const opts = body
    ? { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }
    : {};
  const res = await fetch(path, opts);
  const payload = await res.json().catch(() => ({ ok: false, error: "bad response" }));
  if (!res.ok || payload.ok === false) throw new Error(payload.error || `HTTP ${res.status}`);
  return payload.data;
}

let toastTimer;
function toast(message, kind = "ok") {
  const node = $("#toast");
  node.textContent = message;
  node.className = `toast ${kind}`;
  node.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { node.hidden = true; }, kind === "err" ? 6000 : 2500);
}

/* Wrap a control action: show errors, refresh state, never leave a dead UI. */
async function act(fn, okMessage) {
  try {
    const data = await fn();
    if (data) Object.assign(STATE, data);
    if (okMessage) toast(okMessage, "ok");
    render();
  } catch (err) {
    toast(err.message, "err");
    // Re-read the truth: the hardware may have partially applied the change.
    try { STATE = await api("/api/state"); render(); } catch { /* keep old view */ }
  }
}

/* ---------------- widgets ---------------- */

function sliderField(opts) {
  const { label, sub, value, min, max, step, unit, disabled, onCommit } = opts;
  const field = el("div", "field");
  const top = el("div", "field-top");
  const left = el("div");
  left.append(el("div", "field-label", label));
  if (sub) left.append(el("div", "field-sub", sub));
  const shown = el("div", "field-value", `${value}${unit || ""}`);
  top.append(left, shown);

  const input = el("input");
  input.type = "range";
  input.min = min; input.max = max; input.step = step || 1;
  input.value = value;
  input.disabled = !!disabled;
  input.addEventListener("input", () => { shown.textContent = `${input.value}${unit || ""}`; });
  input.addEventListener("change", () => onCommit(Number(input.value)));

  field.append(top, input);
  return field;
}

function selectField(label, sub, choices, current, onChange, disabled) {
  const field = el("div", "field");
  const top = el("div", "field-top");
  const left = el("div");
  left.append(el("div", "field-label", label));
  if (sub) left.append(el("div", "field-sub", sub));
  const select = el("select");
  choices.forEach(([val, text]) => {
    const opt = el("option", null, text);
    opt.value = val;
    if (String(val) === String(current)) opt.selected = true;
    select.append(opt);
  });
  select.disabled = !!disabled;
  select.addEventListener("change", () => onChange(select.value));
  top.append(left);
  field.append(top, select);
  return field;
}

function switchField(label, sub, on, onToggle, disabled) {
  const wrap = el("div", "switch");
  const left = el("div");
  left.append(el("div", "field-label", label));
  if (sub) left.append(el("div", "field-sub", sub));
  const btn = el("button", "toggle");
  btn.setAttribute("aria-pressed", on ? "true" : "false");
  btn.setAttribute("aria-label", label);
  btn.disabled = !!disabled;
  btn.addEventListener("click", () => onToggle(!on));
  wrap.append(left, btn);
  return wrap;
}

/* ---------------- attribute metadata ---------------- */

/* asusctl exposes raw firmware names; these make them readable. Anything not
   listed still renders, using the firmware's own display_name. */
const ENUM_LABELS = {
  gpu_mux_mode: { 0: "Ultimate — dGPU drives the display", 1: "Optimus — hybrid (battery friendly)" },
  dgpu_disable: { 0: "dGPU available", 1: "dGPU disabled" },
  panel_overdrive: { 0: "Off", 1: "On — faster pixel response" },
  boot_sound: { 0: "Silent", 1: "Play the ROG chime" },
  screen_auto_brightness: { 0: "Off", 1: "On" },
  charge_mode: { 0: "Standard", 1: "Balanced", 2: "Maximum lifespan" },
};

const FRIENDLY = {
  ppt_pl1_spl: ["CPU sustained (PL1)", "Long-run power budget"],
  ppt_pl2_sppt: ["CPU boost (PL2)", "Short bursts"],
  ppt_pl3_fppt: ["CPU peak (PL3)", "Very brief spikes"],
  nv_temp_target: ["GPU temp limit", "Throttles the dGPU at this point"],
  nv_dynamic_boost: ["GPU dynamic boost", "Extra watts shifted from CPU to GPU"],
  nv_tgp: ["GPU total power", "Board power limit"],
  nv_base_tgp: ["GPU base power", "Reported by firmware, read-only"],
  gpu_mux_mode: ["Display MUX", "Needs a reboot"],
  dgpu_disable: ["Discrete GPU", null],
  panel_overdrive: ["Panel overdrive", null],
  boot_sound: ["Boot sound", null],
  charge_mode: ["Charge mode", "Reported by firmware"],
  screen_auto_brightness: ["Auto brightness", null],
};

const GROUPS = {
  "#power-attrs": ["ppt_pl1_spl", "ppt_pl2_sppt", "ppt_pl3_fppt"],
  "#gpu-attrs": ["gpu_mux_mode", "dgpu_disable", "nv_tgp", "nv_dynamic_boost",
                 "nv_temp_target", "nv_base_tgp"],
  "#misc-attrs": ["panel_overdrive", "screen_auto_brightness", "boot_sound", "charge_mode"],
};

const UNITS = {
  ppt_pl1_spl: " W", ppt_pl2_sppt: " W", ppt_pl3_fppt: " W",
  nv_tgp: " W", nv_base_tgp: " W", nv_dynamic_boost: " W",
  nv_temp_target: " °C",
};

function attributeControl(attr) {
  const [label, sub] = FRIENDLY[attr.name] || [attr.label, null];

  if (attr.type === "enumeration") {
    const labels = ENUM_LABELS[attr.name] || {};
    const choices = attr.choices.map((v) => [v, labels[v] ?? String(v)]);
    // charge_mode is reported by firmware but rejected on write on this board.
    const readOnly = attr.name === "charge_mode";
    return selectField(label, sub, choices, attr.current,
      (value) => act(() => api("/api/attribute", { name: attr.name, value: Number(value) }),
                      `${label} set`),
      readOnly);
  }

  // An integer with no usable range is informational only.
  const unusable = attr.min === null || attr.max === null || attr.min >= attr.max;
  if (unusable) {
    const field = el("div", "field");
    const top = el("div", "field-top");
    const left = el("div");
    left.append(el("div", "field-label", label));
    if (sub) left.append(el("div", "field-sub", sub));
    top.append(left, el("div", "field-value", `${attr.current}${UNITS[attr.name] || ""}`));
    field.append(top);
    return field;
  }

  return sliderField({
    label, sub,
    value: attr.current, min: attr.min, max: attr.max, step: attr.step || 1,
    unit: UNITS[attr.name] || "",
    onCommit: (value) => act(
      () => api("/api/attribute", { name: attr.name, value }),
      `${label} → ${value}${UNITS[attr.name] || ""}`),
  });
}

/* ---------------- fan curve editor ---------------- */

const CURVE = { w: 620, h: 260, pad: { l: 34, r: 12, t: 12, b: 26 },
                tMin: 20, tMax: 100 };

function curveScales() {
  const { w, h, pad, tMin, tMax } = CURVE;
  const iw = w - pad.l - pad.r;
  const ih = h - pad.t - pad.b;
  return {
    x: (t) => pad.l + ((t - tMin) / (tMax - tMin)) * iw,
    y: (p) => pad.t + (1 - p / 100) * ih,
    invX: (px) => tMin + ((px - pad.l) / iw) * (tMax - tMin),
    invY: (py) => (1 - (py - pad.t) / ih) * 100,
    iw, ih,
  };
}

function svgEl(tag, attrs) {
  const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
  for (const [k, v] of Object.entries(attrs || {})) node.setAttribute(k, v);
  return node;
}

function currentTempFor(fan) {
  if (!latestSnapshot) return null;
  const temps = latestSnapshot.temperatures || [];
  if (fan === "cpu" || fan === "mid") {
    const t = temps.find((x) => x.label.includes("Tctl"));
    return t ? t.celsius : null;
  }
  const dgpu = latestSnapshot.dgpu;
  return dgpu && dgpu.celsius != null ? dgpu.celsius : null;
}

function renderCurve() {
  const host = $("#curve-host");
  host.textContent = "";

  const info = STATE.fan_curves;
  if (!info || !info.available) {
    host.append(el("div", "note info",
      (info && info.reason) || "Fan curves are not available on this machine."));
    return;
  }

  const points = draftCurves[activeFan];
  if (!points) {
    host.append(el("div", "note info", `No curve data for the ${activeFan} fan.`));
    return;
  }

  const { w, h, pad, tMin, tMax } = CURVE;
  const s = curveScales();
  const svg = svgEl("svg", {
    class: "curve", viewBox: `0 0 ${w} ${h}`,
    preserveAspectRatio: "xMidYMid meet", role: "img",
    "aria-label": `${activeFan} fan curve`,
  });

  // grid + axes
  for (let p = 0; p <= 100; p += 25) {
    svg.append(svgEl("line", { class: "grid-line", x1: pad.l, y1: s.y(p), x2: w - pad.r, y2: s.y(p) }));
    const label = svgEl("text", { class: "axis-text", x: pad.l - 6, y: s.y(p) + 3, "text-anchor": "end" });
    label.textContent = `${p}%`;
    svg.append(label);
  }
  for (let t = tMin; t <= tMax; t += 20) {
    svg.append(svgEl("line", { class: "grid-line", x1: s.x(t), y1: pad.t, x2: s.x(t), y2: h - pad.b }));
    const label = svgEl("text", { class: "axis-text", x: s.x(t), y: h - pad.b + 14, "text-anchor": "middle" });
    label.textContent = `${t}°`;
    svg.append(label);
  }

  const path = points.map((p) => `${s.x(p.temp)},${s.y(p.percent)}`).join(" ");
  svg.append(svgEl("polygon", {
    class: "curve-area",
    points: `${s.x(points[0].temp)},${s.y(0)} ${path} ${s.x(points[points.length - 1].temp)},${s.y(0)}`,
  }));
  svg.append(svgEl("polyline", { class: "curve-line", points: path }));

  // where the chip actually is right now
  const now = currentTempFor(activeFan);
  if (now != null && now >= tMin && now <= tMax) {
    svg.append(svgEl("line", { class: "now-line", x1: s.x(now), y1: pad.t, x2: s.x(now), y2: h - pad.b }));
    const tag = svgEl("text", { class: "now-text", x: s.x(now) + 4, y: pad.t + 11 });
    tag.textContent = `now ${now}°`;
    svg.append(tag);
  }

  points.forEach((point, index) => {
    const knob = svgEl("circle", {
      class: "knob", cx: s.x(point.temp), cy: s.y(point.percent), r: 7,
      tabindex: "0", role: "slider",
      "aria-label": `point ${index + 1}: ${point.temp} degrees, ${point.percent} percent`,
    });

    const move = (event) => {
      const rect = svg.getBoundingClientRect();
      // viewBox units != CSS pixels; convert through the rendered size.
      const px = ((event.clientX - rect.left) / rect.width) * w;
      const py = ((event.clientY - rect.top) / rect.height) * h;

      // Keep points monotonic in temperature so the firmware accepts them.
      const lowT = index === 0 ? tMin : points[index - 1].temp + 1;
      const highT = index === points.length - 1 ? tMax : points[index + 1].temp - 1;

      point.temp = Math.round(Math.min(highT, Math.max(lowT, s.invX(px))));
      point.percent = Math.round(Math.min(100, Math.max(0, s.invY(py))));
      renderCurve();
    };

    const stop = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", stop);
    };

    knob.addEventListener("pointerdown", (event) => {
      event.preventDefault();
      knob.classList.add("dragging");
      window.addEventListener("pointermove", move);
      window.addEventListener("pointerup", stop, { once: true });
    });

    knob.addEventListener("keydown", (event) => {
      const step = event.shiftKey ? 5 : 1;
      let handled = true;
      if (event.key === "ArrowUp") point.percent = Math.min(100, point.percent + step);
      else if (event.key === "ArrowDown") point.percent = Math.max(0, point.percent - step);
      else if (event.key === "ArrowRight") point.temp = Math.min(tMax, point.temp + step);
      else if (event.key === "ArrowLeft") point.temp = Math.max(tMin, point.temp - step);
      else handled = false;
      if (handled) { event.preventDefault(); renderCurve(); }
    });

    svg.append(knob);
  });

  host.append(svg);
}

function renderFanTabs() {
  const tabs = $("#fan-tabs");
  tabs.textContent = "";
  const curves = (STATE.fan_curves && STATE.fan_curves.curves) || [];
  curves.forEach((curve) => {
    const btn = el("button", null, `${curve.fan} fan`);
    btn.setAttribute("aria-pressed", curve.fan === activeFan ? "true" : "false");
    btn.addEventListener("click", () => { activeFan = curve.fan; renderFanTabs(); renderCurve(); });
    tabs.append(btn);
  });
  const enabled = curves.length > 0;
  $("#curve-save").disabled = !enabled;
  $("#curve-reset").disabled = !enabled;
}

function seedDrafts() {
  draftCurves = {};
  const curves = (STATE.fan_curves && STATE.fan_curves.curves) || [];
  curves.forEach((c) => { draftCurves[c.fan] = c.points.map((p) => ({ ...p })); });
  if (!draftCurves[activeFan] && curves.length) activeFan = curves[0].fan;
}

/* ---------------- sections ---------------- */

function renderProfile() {
  const box = $("#profile-switch");
  box.textContent = "";
  const { current, choices } = STATE.profile;
  choices.forEach((name) => {
    const btn = el("button", null, name);
    btn.setAttribute("aria-pressed", name === current ? "true" : "false");
    btn.addEventListener("click", () => {
      if (name === current) return;
      act(async () => {
        const data = await api("/api/profile", { profile: name });
        seedFromProfileChange(data);
        return data;
      }, `Profile: ${name}`);
    });
    box.append(btn);
  });
  $("#reboot-note").hidden = !STATE.pending_reboot;

  // asusd swaps the active profile when power source changes; without saying
  // so, that reads as the machine changing settings by itself.
  const host = $("#profile-defaults");
  host.textContent = "";
  const { ac_profile: onAc, battery_profile: onBat } = STATE.profile;
  if (onAc || onBat) {
    const note = el("div", "note info");
    note.append(document.createTextNode(
      `Switches automatically: ${onAc || "?"} on AC, ${onBat || "?"} on battery.`));
    const row = el("div", "row");
    row.style.marginTop = "8px";
    [["ac", "Use current on AC"], ["battery", "Use current on battery"]].forEach(([slot, label]) => {
      const btn = el("button", "ghost", label);
      btn.addEventListener("click", () => act(
        () => api("/api/profile", { profile: STATE.profile.current, for: slot }),
        `${STATE.profile.current} saved for ${slot}`));
      row.append(btn);
    });
    note.append(row);
    host.append(note);
  }
}

function seedFromProfileChange(data) {
  STATE.profile = data.profile;
  STATE.attributes = data.attributes;
  STATE.fan_curves = data.fan_curves;
  seedDrafts();
}

function renderBattery() {
  const host = $("#battery");
  host.textContent = "";
  const bat = STATE.battery;
  if (!bat.present) { host.append(el("div", "note info", "No battery detected.")); return; }

  const readouts = el("div", "readouts");
  [["Charge", `${bat.capacity}%`], ["Status", bat.status || "—"]].forEach(([k, v]) => {
    const card = el("div", "readout");
    card.append(el("div", "k", k), el("div", "v", v));
    readouts.append(card);
  });
  host.append(readouts);

  host.append(sliderField({
    label: "Charge limit",
    sub: "Stopping around 60–80% greatly extends pack life if you run on AC",
    value: bat.charge_limit ?? 100, min: 20, max: 100, step: 5, unit: "%",
    onCommit: (percent) => act(() => api("/api/battery-limit", { percent }),
                               `Charge limit → ${percent}%`),
  }));
}

function renderAura() {
  const host = $("#aura");
  host.textContent = "";
  const aura = STATE.aura;

  host.append(selectField("Brightness", null,
    aura.brightness_choices.map((v) => [v, v]), aura.brightness || "off",
    (level) => act(() => api("/api/aura-brightness", { level }), `Keyboard: ${level}`)));

  const effectRow = el("div", "field");
  const top = el("div", "field-top");
  top.append(el("div", "field-label", "Effect"));
  const select = el("select");
  aura.effects.forEach((name) => {
    const opt = el("option", null, name.replace(/-/g, " "));
    opt.value = name;
    select.append(opt);
  });
  const colour = el("input");
  colour.type = "color";
  colour.value = "#ff3d5a";
  const apply = el("button", "primary", "Apply");
  apply.addEventListener("click", () => act(
    () => api("/api/aura-effect", { effect: select.value, colour: colour.value }),
    `Effect: ${select.value}`));
  top.append(select);
  effectRow.append(top);
  const row = el("div", "row");
  row.append(colour, apply);
  effectRow.append(row);
  host.append(effectRow);
}

function renderSlash() {
  const host = $("#slash");
  host.textContent = "";
  const slash = STATE.slash;
  if (!slash.supported) {
    host.append(el("div", "note info", "This machine has no Slash light bar."));
    return;
  }

  host.append(switchField("Light bar", "Master on/off", true,
    (on) => act(() => api("/api/slash", { enabled: on }), on ? "Light bar on" : "Light bar off")));

  host.append(selectField("Animation", "“Loading” is the classic ROG sweep",
    slash.modes.map((m) => [m, m]), null,
    (mode) => act(() => api("/api/slash", { mode }), `Animation: ${mode}`)));

  host.append(sliderField({
    label: "Brightness", value: 128, min: 0, max: 255, step: 1,
    onCommit: (brightness) => act(() => api("/api/slash", { brightness }), "Brightness set"),
  }));

  const toggles = [
    ["show_on_boot", "Show on boot"],
    ["show_on_shutdown", "Show on shutdown"],
    ["show_on_sleep", "Show on sleep"],
    ["show_on_battery", "Show on battery"],
    ["show_battery_warning", "Low battery warning"],
  ];
  toggles.forEach(([key, label]) => {
    host.append(switchField(label, null, true,
      (on) => act(() => api("/api/slash", { [key]: on }), `${label}: ${on ? "on" : "off"}`)));
  });
  host.append(el("div", "note info",
    "asusctl cannot read these back, so the switches show the action, not stored state."));
}

function renderGraphics() {
  const host = $("#gpu-mode");
  host.textContent = "";
  const gfx = STATE.graphics;
  if (!gfx.supported) {
    host.append(el("div", "note info",
      gfx.error ? `supergfxd: ${gfx.error}` : "supergfxctl is not installed, so mode switching is unavailable."));
    return;
  }
  host.append(selectField("GPU mode", "Switching logs you out", 
    gfx.choices.map((m) => [m, m]), gfx.mode,
    (mode) => {
      if (mode === gfx.mode) return;
      if (!confirm(`Switch graphics to ${mode}? This usually ends your session.`)) { render(); return; }
      act(() => api("/api/graphics", { mode }), `Graphics → ${mode}`);
    }));
  if (gfx.pending && gfx.pending !== "Unknown" && gfx.pending !== gfx.mode) {
    host.append(el("div", "note warn", `Pending change: ${gfx.pending}`));
  }
}

function renderNumpad() {
  const host = $("#numpad");
  host.textContent = "";
  const pad = STATE.numpad;
  if (!pad.supported) {
    host.append(el("div", "note info",
      "asus-numberpad-driver is not installed, so there is nothing to control."));
    return;
  }
  host.append(switchField("NumberPad", "Lights up the keypad on the trackpad",
    pad.enabled, (on) => act(() => api("/api/numpad", { enabled: on }),
                             on ? "NumberPad on" : "NumberPad off")));

  host.append(sliderField({
    label: "Auto-off after inactivity",
    sub: "0 disables the timeout entirely",
    value: Number(pad.inactivity_timeout || 120), min: 0, max: 120, step: 10, unit: " s",
    onCommit: (v) => act(
      () => api("/api/numpad", { disable_due_inactivity_time: v }), `Auto-off → ${v}s`),
  }));

  host.append(sliderField({
    label: "Hold time to activate",
    sub: "How long to press the top-right corner",
    value: Number(pad.activation_time || 1), min: 0.2, max: 3, step: 0.1, unit: " s",
    onCommit: (v) => act(
      () => api("/api/numpad", { activation_time: v }), `Hold time → ${v}s`),
  }));
}

function renderAttributes() {
  const byName = Object.fromEntries(STATE.attributes.map((a) => [a.name, a]));
  for (const [selector, names] of Object.entries(GROUPS)) {
    const host = $(selector);
    host.textContent = "";
    let added = 0;
    names.forEach((name) => {
      const attr = byName[name];
      if (!attr) return;
      host.append(attributeControl(attr));
      added += 1;
    });
    if (!added) host.append(el("div", "note info", "Nothing here is exposed by this firmware."));
  }
}

function render() {
  if (!STATE) return;
  const model = STATE.model || {};
  $("#model").textContent = [model.family, model.board].filter(Boolean).join(" · ")
    || model.product || "unknown model";
  renderProfile();
  renderAttributes();
  renderBattery();
  renderAura();
  renderSlash();
  renderGraphics();
  renderNumpad();
  renderFanTabs();
  renderCurve();
}

/* ---------------- live telemetry ---------------- */

function tempClass(celsius) {
  if (celsius == null) return "";
  if (celsius >= 85) return "hot";
  if (celsius >= 70) return "warm";
  return "cool";
}

function renderLive(snap) {
  latestSnapshot = snap;

  const temps = snap.temperatures || [];
  const cpu = temps.find((t) => t.label.includes("Tctl"));
  const dgpu = snap.dgpu || {};
  const power = snap.power || {};

  const badges = $("#live-badges");
  badges.textContent = "";
  const items = [
    ["CPU", cpu ? `${cpu.celsius}°` : "—", tempClass(cpu && cpu.celsius)],
    ["GPU", dgpu.celsius != null ? `${dgpu.celsius}°` : "—", tempClass(dgpu.celsius)],
    ["GPU load", dgpu.util != null ? `${dgpu.util}%` : "—", ""],
    [power.on_ac ? "AC" : "Battery",
     power.on_ac ? "plugged" : `${power.battery_watts ?? "—"} W`, ""],
  ];
  items.forEach(([k, v, cls]) => {
    const badge = el("div", `badge ${cls}`);
    badge.append(el("b", null, v), el("span", null, k));
    badges.append(badge);
  });

  const readouts = $("#readouts");
  readouts.textContent = "";
  const cards = [
    ["CPU package", cpu ? cpu.celsius : null, "°C"],
    ["dGPU", dgpu.celsius ?? null, "°C"],
    ["dGPU power", dgpu.watts ?? null, "W"],
    ["dGPU clock", dgpu.clock_mhz ?? null, "MHz"],
    ["VRAM", dgpu.vram_used_mb != null ? Math.round(dgpu.vram_used_mb) : null, "MB"],
    ["Load avg", snap.load ?? null, ""],
  ];
  cards.forEach(([k, v, unit]) => {
    const card = el("div", "readout");
    const value = el("div", "v");
    value.textContent = v == null ? "—" : String(v);
    if (unit && v != null) value.append(el("small", null, unit));
    card.append(el("div", "k", k), value);
    readouts.append(card);
  });

  const fansHost = $("#fans");
  fansHost.textContent = "";
  (snap.fans || []).forEach((fan) => {
    // ~6000rpm is the practical ceiling on these chassis; used only for the bar.
    const pct = Math.min(100, Math.round((fan.rpm / 6000) * 100));
    const row = el("div", "fan");
    const track = el("div", "track");
    const fill = el("div", "fill");
    fill.style.width = `${pct}%`;
    track.append(fill);
    row.append(el("div", "name", fan.label), track,
                el("div", "rpm", `${fan.rpm} rpm`));
    fansHost.append(row);
  });

  // Keep the "now" marker on the curve in step with reality.
  if (STATE && STATE.fan_curves && STATE.fan_curves.available) renderCurve();
}

function connectStream() {
  const source = new EventSource("/api/stream");
  source.onopen = () => { $("#stream-state").textContent = "live"; };
  source.onmessage = (event) => {
    try { renderLive(JSON.parse(event.data)); } catch { /* skip a bad frame */ }
  };
  source.onerror = () => {
    $("#stream-state").textContent = "reconnecting…";
    // EventSource retries on its own; no manual backoff needed.
  };
}

/* ---------------- boot ---------------- */

$("#curve-save").addEventListener("click", () => act(async () => {
  const data = await api("/api/fan-curve", {
    profile: STATE.profile.current,
    fan: activeFan,
    points: draftCurves[activeFan],
  });
  STATE.fan_curves = data;
  seedDrafts();
  return {};
}, `${activeFan} curve applied`));

$("#curve-reset").addEventListener("click", () => act(async () => {
  const data = await api("/api/fan-curve-reset", { profile: STATE.profile.current });
  STATE.fan_curves = data;
  seedDrafts();
  return {};
}, "Fan curves reset"));

(async function boot() {
  try {
    STATE = await api("/api/state");
    seedDrafts();
    render();
    connectStream();
  } catch (err) {
    document.body.prepend(el("div", "note warn", `Could not reach the ROG Deck service: ${err.message}`));
  }
})();
