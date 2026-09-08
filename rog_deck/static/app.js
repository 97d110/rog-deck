/* ROG Deck front-end. No framework, no build step. */

const $ = (sel) => document.querySelector(sel);
const el = (tag, cls, text) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined) n.textContent = text;
  return n;
};
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

let STATE = null;
let activeFan = "cpu";
let draftCurves = {};
let latestSnapshot = null;

/* asusctl cannot read back the active aura effect, so what the user picked is
   tracked here for the session rather than pretended to be hardware state. */
let auraDraft = { effect: null, colour: "#ff0000", colour2: "#0000ff",
                  speed: "med", direction: "left" };

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
  toastTimer = setTimeout(() => { node.hidden = true; }, kind === "err" ? 6000 : 2200);
}

async function act(fn, okMessage) {
  try {
    const data = await fn();
    if (data) Object.assign(STATE, data);
    if (okMessage) toast(okMessage, "ok");
    render();
  } catch (err) {
    toast(err.message, "err");
    try { STATE = await api("/api/state"); render(); } catch { /* keep view */ }
  }
}

/* ---------------- theme ---------------- */

function applyTheme(theme) {
  if (!theme || !theme.colors) return;
  const root = document.documentElement;
  for (const [name, value] of Object.entries(theme.colors)) {
    root.style.setProperty(`--c-${name}`, value);
  }
  root.style.colorScheme = theme.mode === "light" ? "light" : "dark";
}

/* ---------------- widgets ---------------- */

/* One click applies. The checked row always shows real state, so there is no
   dropdown that can drift out of step with the hardware. */
function radioGroup(choices, current, onPick, opts = {}) {
  const box = el("div", `radios${opts.cols ? ` cols-${opts.cols}` : ""}`);
  box.setAttribute("role", "radiogroup");
  if (opts.label) box.setAttribute("aria-label", opts.label);
  choices.forEach(([value, text]) => {
    const btn = el("button", null, text);
    btn.setAttribute("role", "radio");
    btn.setAttribute("aria-checked", String(value) === String(current) ? "true" : "false");
    btn.addEventListener("click", () => onPick(value));
    box.append(btn);
  });
  return box;
}

function labelled(label, sub, control) {
  const field = el("div", "field");
  const top = el("div", "field-top");
  const left = el("div");
  left.append(el("div", "field-label", label));
  if (sub) left.append(el("div", "field-sub", sub));
  top.append(left);
  field.append(top);
  if (control) field.append(control);
  return field;
}

function sliderField({ label, sub, value, min, max, step, unit, disabled, onCommit }) {
  const field = el("div", "field");
  const top = el("div", "field-top");
  const left = el("div");
  left.append(el("div", "field-label", label));
  if (sub) left.append(el("div", "field-sub", sub));
  const shown = el("div", "field-val", `${value}${unit || ""}`);
  top.append(left, shown);

  const input = el("input");
  input.type = "range";
  input.min = min; input.max = max; input.step = step || 1; input.value = value;
  input.disabled = !!disabled;
  input.addEventListener("input", () => { shown.textContent = `${input.value}${unit || ""}`; });
  input.addEventListener("change", () => onCommit(Number(input.value)));
  field.append(top, input);
  return field;
}

function checkRow(label, on, onToggle, disabled) {
  const row = el("div", "check");
  row.append(el("span", null, label));
  const btn = el("button");
  btn.setAttribute("aria-pressed", on ? "true" : "false");
  btn.setAttribute("aria-label", label);
  btn.disabled = !!disabled;
  btn.addEventListener("click", () => onToggle(!on));
  row.append(btn);
  return row;
}

/* ---------------- gauges ---------------- */

function zoneCss(range) {
  const span = range.max - range.min || 1;
  const warnAt = clamp(((range.warn - range.min) / span) * 100, 0, 100);
  const critAt = clamp(((range.crit - range.min) / span) * 100, 0, 100);
  return `linear-gradient(90deg,
    var(--c-green) 0 ${warnAt}%,
    var(--c-yellow) ${warnAt}% ${critAt}%,
    var(--c-red) ${critAt}% 100%)`;
}

function gauge({ name, value, unit, range, decimals = 0, limitWord = "throttles",
                plain = false }) {
  const r = range || { min: 0, warn: 70, crit: 90, max: 100, source: "default" };
  const span = r.max - r.min || 1;
  const pct = clamp(((value - r.min) / span) * 100, 0, 100);

  // `plain` is for values with no "too high" end - battery charge, where more
  // is simply better - so they get a neutral bar instead of a red zone.
  let level = "";
  if (!plain && value >= r.crit) level = "is-bad";
  else if (!plain && value >= r.warn) level = "is-warn";

  const g = el("div", `gauge ${level}`);
  g.append(el("div", "g-name", name));

  const val = el("div", "g-val");
  val.textContent = value == null ? "—" : value.toFixed(decimals);
  if (unit) val.append(el("small", null, unit));
  g.append(val);

  const wrap = el("div", "g-wrap");
  const track = el("div", "g-track");
  const zones = el("div", "g-zones");
  if (!plain) zones.style.background = zoneCss(r);
  const fill = el("div", "g-fill");
  fill.style.width = `${pct}%`;
  const mark = el("div", "g-mark");
  mark.style.left = `calc(${pct}% - 1px)`;
  track.append(zones, fill, mark);
  wrap.append(track);
  g.append(wrap);

  const ticks = el("div", "g-ticks");
  ticks.append(el("em", null, `${Math.round(r.min)}${unit || ""}`));
  if (plain || !limitWord) {
    ticks.append(el("em", null, ""));
  } else {
    ticks.append(el("em", null,
      `${limitWord} ${Math.round(r.crit)}${unit || ""}` +
      (r.source === "estimate" ? " (est)" : "")));
  }
  ticks.append(el("em", null, `${Math.round(r.max)}${unit || ""}`));
  g.append(ticks);
  return g;
}

function renderGauges(snap) {
  const host = $("#gauges");
  host.textContent = "";
  if (!snap) return;

  const temps = snap.temperatures || [];
  const dgpu = snap.dgpu || {};

  // The headline numbers first: the ones that actually throttle the machine.
  const cpu = temps.find((t) => t.label.includes("Tctl"));
  if (cpu) host.append(gauge({ name: "CPU package", value: cpu.celsius, unit: "°", range: cpu.range, decimals: 1 }));
  if (dgpu.celsius != null) {
    host.append(gauge({ name: `GPU  ${dgpu.name ? dgpu.name.replace(/^NVIDIA GeForce /, "") : ""}`,
                        value: dgpu.celsius, unit: "°", range: dgpu.temp_range }));
  }
  if (dgpu.watts != null) {
    host.append(gauge({ name: "GPU power draw", value: dgpu.watts, unit: "W",
                        range: dgpu.power_range, decimals: 1, limitWord: "limit" }));
  }
  (snap.fans || []).forEach((fan) => {
    host.append(gauge({ name: `${fan.label} fan`, value: fan.rpm, unit: "",
                        range: fan.range, limitWord: "full tilt" }));
  });
  // Drive temps last: informative, rarely the thing that bites.
  temps.filter((t) => t.kind === "ssd" && t.label.includes("Composite"))
       .forEach((t) => host.append(
         gauge({ name: t.label, value: t.celsius, unit: "°", range: t.range, decimals: 1 })));
}

/* ---------------- attributes ---------------- */

const ENUM_LABELS = {
  gpu_mux_mode: { 0: "ultimate · dGPU drives display", 1: "optimus · hybrid" },
  dgpu_disable: { 0: "dGPU available", 1: "dGPU disabled" },
  panel_overdrive: { 0: "off", 1: "on · faster pixels" },
  boot_sound: { 0: "silent", 1: "ROG chime" },
  screen_auto_brightness: { 0: "off", 1: "on" },
  charge_mode: { 0: "standard", 1: "balanced", 2: "max lifespan" },
};

const FRIENDLY = {
  ppt_pl1_spl: ["CPU sustained (PL1)", "long-run power budget"],
  ppt_pl2_sppt: ["CPU boost (PL2)", "short bursts"],
  ppt_pl3_fppt: ["CPU peak (PL3)", "brief spikes"],
  nv_temp_target: ["GPU temp limit", "throttles the dGPU here"],
  nv_dynamic_boost: ["GPU dynamic boost", "watts shifted from CPU to GPU"],
  nv_tgp: ["GPU total power", "board power limit"],
  nv_base_tgp: ["GPU base power", "firmware-reported, read-only"],
  gpu_mux_mode: ["display MUX", "needs a reboot"],
  dgpu_disable: ["discrete GPU", null],
  panel_overdrive: ["panel overdrive", null],
  boot_sound: ["boot sound", null],
  charge_mode: ["charge mode", "firmware-reported"],
  screen_auto_brightness: ["auto brightness", null],
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
    const readOnly = attr.name === "charge_mode";
    const group = radioGroup(choices, attr.current,
      (value) => act(() => api("/api/attribute", { name: attr.name, value: Number(value) }), `${label} set`),
      { label });
    if (readOnly) group.querySelectorAll("button").forEach((b) => { b.disabled = true; });
    return labelled(label, readOnly ? "read-only on this board" : sub, group);
  }

  const unusable = attr.min === null || attr.max === null || attr.min >= attr.max;
  if (unusable) {
    const field = labelled(label, sub, null);
    field.querySelector(".field-top").append(
      el("div", "field-val", `${attr.current}${UNITS[attr.name] || ""}`));
    return field;
  }

  return sliderField({
    label, sub,
    value: attr.current, min: attr.min, max: attr.max, step: attr.step || 1,
    unit: UNITS[attr.name] || "",
    onCommit: (value) => act(() => api("/api/attribute", { name: attr.name, value }),
                             `${label} → ${value}${UNITS[attr.name] || ""}`),
  });
}

/* ---------------- fan curve ---------------- */

const CURVE = { w: 620, h: 250, pad: { l: 34, r: 12, t: 12, b: 26 }, tMin: 20, tMax: 100 };

function curveScales() {
  const { w, h, pad, tMin, tMax } = CURVE;
  const iw = w - pad.l - pad.r, ih = h - pad.t - pad.b;
  return {
    x: (t) => pad.l + ((t - tMin) / (tMax - tMin)) * iw,
    y: (p) => pad.t + (1 - p / 100) * ih,
    invX: (px) => tMin + ((px - pad.l) / iw) * (tMax - tMin),
    invY: (py) => (1 - (py - pad.t) / ih) * 100,
  };
}

function svgEl(tag, attrs) {
  const n = document.createElementNS("http://www.w3.org/2000/svg", tag);
  for (const [k, v] of Object.entries(attrs || {})) n.setAttribute(k, v);
  return n;
}

function currentTempFor(fan) {
  if (!latestSnapshot) return null;
  if (fan === "gpu") {
    const d = latestSnapshot.dgpu;
    return d && d.celsius != null ? d.celsius : null;
  }
  const t = (latestSnapshot.temperatures || []).find((x) => x.label.includes("Tctl"));
  return t ? t.celsius : null;
}

function renderCurve() {
  const host = $("#curve-host");
  host.textContent = "";
  const info = STATE.fan_curves;
  if (!info || !info.available) {
    host.append(el("div", "note info", (info && info.reason) || "fan curves unavailable"));
    return;
  }
  const points = draftCurves[activeFan];
  if (!points) { host.append(el("div", "note info", `no curve for the ${activeFan} fan`)); return; }

  const { w, h, pad, tMin, tMax } = CURVE;
  const s = curveScales();
  const svg = svgEl("svg", { class: "curve", viewBox: `0 0 ${w} ${h}`,
    preserveAspectRatio: "xMidYMid meet", role: "img",
    "aria-label": `${activeFan} fan curve` });

  for (let p = 0; p <= 100; p += 25) {
    svg.append(svgEl("line", { class: "grid-line", x1: pad.l, y1: s.y(p), x2: w - pad.r, y2: s.y(p) }));
    const t = svgEl("text", { class: "axis-text", x: pad.l - 6, y: s.y(p) + 3, "text-anchor": "end" });
    t.textContent = `${p}%`;
    svg.append(t);
  }
  for (let c = tMin; c <= tMax; c += 20) {
    svg.append(svgEl("line", { class: "grid-line", x1: s.x(c), y1: pad.t, x2: s.x(c), y2: h - pad.b }));
    const t = svgEl("text", { class: "axis-text", x: s.x(c), y: h - pad.b + 14, "text-anchor": "middle" });
    t.textContent = `${c}°`;
    svg.append(t);
  }

  const path = points.map((p) => `${s.x(p.temp)},${s.y(p.percent)}`).join(" ");
  svg.append(svgEl("polygon", { class: "curve-area",
    points: `${s.x(points[0].temp)},${s.y(0)} ${path} ${s.x(points[points.length - 1].temp)},${s.y(0)}` }));
  svg.append(svgEl("polyline", { class: "curve-line", points: path }));

  const now = currentTempFor(activeFan);
  if (now != null && now >= tMin && now <= tMax) {
    svg.append(svgEl("line", { class: "now-line", x1: s.x(now), y1: pad.t, x2: s.x(now), y2: h - pad.b }));
    const tag = svgEl("text", { class: "now-text", x: s.x(now) + 4, y: pad.t + 11 });
    tag.textContent = `now ${now}°`;
    svg.append(tag);
  }

  points.forEach((point, index) => {
    const knob = svgEl("circle", { class: "knob", cx: s.x(point.temp), cy: s.y(point.percent),
      r: 6, tabindex: "0", role: "slider",
      "aria-label": `point ${index + 1}: ${point.temp} degrees, ${point.percent} percent` });

    const move = (event) => {
      const rect = svg.getBoundingClientRect();
      const px = ((event.clientX - rect.left) / rect.width) * w;
      const py = ((event.clientY - rect.top) / rect.height) * h;
      const lowT = index === 0 ? tMin : points[index - 1].temp + 1;
      const highT = index === points.length - 1 ? tMax : points[index + 1].temp - 1;
      point.temp = Math.round(clamp(s.invX(px), lowT, highT));
      point.percent = Math.round(clamp(s.invY(py), 0, 100));
      renderCurve();
    };
    const stop = () => window.removeEventListener("pointermove", move);

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
  $("#curve-save").disabled = !curves.length;
  $("#curve-reset").disabled = !curves.length;
}

function seedDrafts() {
  draftCurves = {};
  const curves = (STATE.fan_curves && STATE.fan_curves.curves) || [];
  curves.forEach((c) => { draftCurves[c.fan] = c.points.map((p) => ({ ...p })); });
  if (!draftCurves[activeFan] && curves.length) activeFan = curves[0].fan;
}

/* ---------------- sections ---------------- */

function renderProfile() {
  const { current, choices, ac_profile: onAc, battery_profile: onBat } = STATE.profile;
  const host = $("#profile-switch");
  host.textContent = "";
  host.append(radioGroup(choices.map((c) => [c, c]), current, (name) => {
    if (name === current) return;
    act(async () => {
      const data = await api("/api/profile", { profile: name });
      STATE.profile = data.profile;
      STATE.attributes = data.attributes;
      STATE.fan_curves = data.fan_curves;
      seedDrafts();
      return {};
    }, `profile → ${name}`);
  }, { label: "Performance profile" }));

  $("#reboot-note").hidden = !STATE.pending_reboot;

  const defaults = $("#profile-defaults");
  defaults.textContent = "";
  if (onAc || onBat) {
    const note = el("div", "note info");
    note.append(document.createTextNode(
      `auto-switches to ${onAc || "?"} on AC, ${onBat || "?"} on battery`));
    const row = el("div", "actions");
    [["ac", "pin current to AC"], ["battery", "pin current to battery"]].forEach(([slot, label]) => {
      const btn = el("button", "btn", label);
      btn.addEventListener("click", () => act(
        () => api("/api/profile", { profile: STATE.profile.current, for: slot }),
        `${STATE.profile.current} pinned to ${slot}`));
      row.append(btn);
    });
    note.append(row);
    defaults.append(note);
  }
}

function renderBattery() {
  const host = $("#battery");
  host.textContent = "";
  const bat = STATE.battery;
  if (!bat.present) { host.append(el("div", "note info", "no battery detected")); return; }
  host.append(gauge({ name: `charge · ${bat.status || "?"}`, value: bat.capacity, unit: "%",
    range: { min: 0, warn: 100, crit: 100, max: 100, source: "hardware" }, plain: true }));
  host.append(sliderField({
    label: "charge limit",
    sub: "60–80% greatly extends pack life if you mostly run on AC",
    value: bat.charge_limit ?? 100, min: 20, max: 100, step: 5, unit: "%",
    onCommit: (percent) => act(() => api("/api/battery-limit", { percent }), `charge limit → ${percent}%`),
  }));
}

/* Keyboard light. Brightness is real, readable hardware state, so it updates
   optimistically then reconciles - the old dropdown appeared to "reset"
   because it repainted from a read that had not caught up yet. */
function renderAura() {
  const host = $("#aura");
  host.textContent = "";
  const aura = STATE.aura;

  host.append(labelled("brightness", null,
    radioGroup(aura.brightness_choices.map((v) => [v, v]), aura.brightness || "off",
      (level) => {
        STATE.aura = { ...aura, brightness: level };   // optimistic
        render();
        act(() => api("/api/aura-brightness", { level }), `keyboard → ${level}`);
      }, { label: "Keyboard brightness", cols: 4 })));

  const args = (aura.effect_args && auraDraft.effect)
    ? (aura.effect_args[auraDraft.effect] || []) : [];

  const apply = (patch) => {
    Object.assign(auraDraft, patch);
    if (!auraDraft.effect) return;
    const accepted = (aura.effect_args && aura.effect_args[auraDraft.effect]) || [];
    const body = { effect: auraDraft.effect };
    // Send only what this effect accepts; asusctl hard-errors on extras.
    accepted.forEach((name) => { body[name] = auraDraft[name]; });
    render();
    act(() => api("/api/aura-effect", body), `effect → ${auraDraft.effect}`);
  };

  host.append(labelled("effect", auraDraft.effect ? null : "pick one to apply it",
    radioGroup(aura.effects.map((e) => [e, e.replace(/-/g, " ")]), auraDraft.effect,
      (effect) => apply({ effect }), { label: "Aura effect" })));

  if (args.includes("colour")) {
    const input = el("input");
    input.type = "color";
    input.value = auraDraft.colour;
    input.addEventListener("change", () => apply({ colour: input.value }));
    host.append(labelled("colour", null, input));
  }
  if (args.includes("colour2")) {
    const input = el("input");
    input.type = "color";
    input.value = auraDraft.colour2;
    input.addEventListener("change", () => apply({ colour2: input.value }));
    host.append(labelled("second colour", null, input));
  }
  if (args.includes("speed")) {
    host.append(labelled("speed", null,
      radioGroup(aura.speeds.map((s) => [s, s]), auraDraft.speed,
        (speed) => apply({ speed }), { label: "Effect speed" })));
  }
  if (args.includes("direction")) {
    host.append(labelled("direction", null,
      radioGroup(aura.directions.map((d) => [d, d]), auraDraft.direction,
        (direction) => apply({ direction }), { label: "Effect direction" })));
  }

  host.append(el("div", "note info",
    "asusctl cannot read the active effect back, so the highlighted effect is what this page last applied."));
}

function renderRipple() {
  const host = $("#ripple");
  host.textContent = "";
  const r = STATE.ripple;
  if (!r) return;
  if (!r.supported) {
    host.append(el("div", "note info",
      "this keyboard is not per-key addressable, so the ripple cannot run"));
    return;
  }
  if (!r.installed) {
    host.append(el("div", "note info",
      "the ripple unit is not installed; run rog-deck/install.sh"));
    return;
  }

  const s = r.settings;
  const push = (patch, message) => act(
    () => api("/api/ripple", patch), message);

  host.append(checkRow("running now", r.active,
    (on) => push({ active: on }, on ? "ripple started" : "ripple stopped")));
  host.append(checkRow("start at login", r.enabled,
    (on) => push({ enabled: on }, on ? "enabled at login" : "disabled at login")));

  const swatch = el("input");
  swatch.type = "color";
  swatch.value = s.colour;
  swatch.addEventListener("change", () => push({ colour: swatch.value }, "glow colour set"));
  host.append(labelled("glow colour", null, swatch));

  const lim = r.limits || {};
  const range = (key, label, sub, unit, step) => {
    const [lo, hi] = lim[key] || [0, 1];
    host.append(sliderField({
      label, sub, value: s[key], min: lo, max: hi, step,
      unit: unit || "",
      onCommit: (value) => push({ [key]: value }, `${label} → ${value}${unit || ""}`),
    }));
  };
  range("brightness", "max brightness", "ceiling for the whole effect", "", 0.05);
  range("speed", "wave speed", "how fast the front travels", "", 0.5);
  range("decay", "fade time", "seconds for a lit key to go dark", " s", 0.05);
  range("base", "idle glow", "brightness when nothing is happening", "", 0.01);
  range("steps", "trail bands", "0 = smooth fade, or N stepped rings", "", 1);

  host.append(el("div", "note info",
    "Changes apply live \u2014 the running effect re-reads its settings. It reads key "
    + "events to know where each wave starts; only the key position is used."));
}

function renderSlash() {
  const host = $("#slash");
  host.textContent = "";
  const slash = STATE.slash;
  if (!slash.supported) { host.append(el("div", "note info", "no Slash light bar on this machine")); return; }

  const row = el("div", "actions");
  row.style.justifyContent = "flex-start";
  [["on", true], ["off", false]].forEach(([label, on]) => {
    const btn = el("button", "btn", label);
    btn.addEventListener("click", () => act(() => api("/api/slash", { enabled: on }),
                                            `light bar ${label}`));
    row.append(btn);
  });
  host.append(labelled("light bar", "master switch", row));

  host.append(labelled("animation", '"loading" is the classic ROG sweep',
    radioGroup(slash.modes.map((m) => [m, m.toLowerCase()]), null,
      (mode) => act(() => api("/api/slash", { mode }), `animation → ${mode}`),
      { label: "Slash animation" })));

  host.append(sliderField({ label: "brightness", value: 128, min: 0, max: 255, step: 1,
    onCommit: (brightness) => act(() => api("/api/slash", { brightness }), "brightness set") }));

  [["show_on_boot", "show on boot"], ["show_on_shutdown", "show on shutdown"],
   ["show_on_sleep", "show on sleep"], ["show_on_battery", "show on battery"],
   ["show_battery_warning", "low battery warning"]].forEach(([key, label]) => {
    const wrap = el("div", "actions");
    wrap.style.justifyContent = "flex-start";
    [["yes", true], ["no", false]].forEach(([text, on]) => {
      const btn = el("button", "btn", text);
      btn.addEventListener("click", () => act(() => api("/api/slash", { [key]: on }),
                                              `${label}: ${text}`));
      wrap.append(btn);
    });
    host.append(labelled(label, null, wrap));
  });

  host.append(el("div", "note info",
    "asusctl cannot read these back, so these send an action rather than showing stored state."));
}

function renderGraphics() {
  const host = $("#gpu-mode");
  host.textContent = "";
  const gfx = STATE.graphics;
  if (!gfx.supported) {
    host.append(el("div", "note info",
      gfx.error ? `supergfxd: ${gfx.error}` : "supergfxctl not installed"));
    return;
  }
  host.append(labelled("GPU mode", "switching usually ends your session",
    radioGroup(gfx.choices.map((m) => [m, m]), gfx.mode, (mode) => {
      if (mode === gfx.mode) return;
      if (!confirm(`Switch graphics to ${mode}? This usually logs you out.`)) { render(); return; }
      act(() => api("/api/graphics", { mode }), `graphics → ${mode}`);
    }, { label: "GPU mode" })));
  if (gfx.pending && gfx.pending !== "Unknown" && gfx.pending !== gfx.mode) {
    host.append(el("div", "note warn", `pending: ${gfx.pending}`));
  }
}

function renderNumpad() {
  const host = $("#numpad");
  host.textContent = "";
  const pad = STATE.numpad;
  if (!pad.supported) { host.append(el("div", "note info", "asus-numberpad-driver not installed")); return; }
  host.append(checkRow("numpad lit", pad.enabled,
    (on) => act(() => api("/api/numpad", { enabled: on }), on ? "numpad on" : "numpad off")));
  host.append(sliderField({ label: "auto-off after idle", sub: "0 disables the timeout",
    value: Number(pad.inactivity_timeout || 120), min: 0, max: 120, step: 10, unit: " s",
    onCommit: (v) => act(() => api("/api/numpad", { disable_due_inactivity_time: v }), `auto-off → ${v}s`) }));
  host.append(sliderField({ label: "corner hold time", sub: "to toggle it by hand",
    value: Number(pad.activation_time || 1), min: 0.2, max: 3, step: 0.1, unit: " s",
    onCommit: (v) => act(() => api("/api/numpad", { activation_time: v }), `hold → ${v}s`) }));
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
    if (!added) host.append(el("div", "note info", "nothing here is exposed by this firmware"));
  }
}

function render() {
  if (!STATE) return;
  const m = STATE.model || {};
  $("#model").textContent = [m.family, m.board].filter(Boolean).join(" · ") || m.product || "";
  renderProfile();
  renderAttributes();
  renderBattery();
  renderAura();
  renderRipple();
  renderSlash();
  renderGraphics();
  renderNumpad();
  renderFanTabs();
  renderCurve();
}

/* ---------------- live ---------------- */

function levelOf(value, range) {
  if (value == null || !range) return "";
  if (value >= range.crit) return "bad";
  if (value >= range.warn) return "warn";
  return "ok";
}

function renderLive(snap) {
  latestSnapshot = snap;
  const temps = snap.temperatures || [];
  const cpu = temps.find((t) => t.label.includes("Tctl"));
  const dgpu = snap.dgpu || {};
  const power = snap.power || {};

  const badges = $("#live-badges");
  badges.textContent = "";
  [
    ["cpu", cpu ? `${cpu.celsius}°` : "—", levelOf(cpu && cpu.celsius, cpu && cpu.range)],
    ["gpu", dgpu.celsius != null ? `${dgpu.celsius}°` : "—", levelOf(dgpu.celsius, dgpu.temp_range)],
    ["load", dgpu.util != null ? `${dgpu.util}%` : "—", ""],
    [power.on_ac ? "ac" : "batt", power.on_ac ? "plugged" : `${power.battery_watts ?? "—"}W`, ""],
  ].forEach(([k, v, cls]) => {
    const b = el("div", `badge ${cls}`);
    b.append(el("i", null, k), el("b", null, v));
    badges.append(b);
  });

  renderGauges(snap);
  if (STATE && STATE.fan_curves && STATE.fan_curves.available) renderCurve();
}

function connectStream() {
  const source = new EventSource("/api/stream");
  source.onopen = () => { $("#stream-state").textContent = "live"; };
  source.onmessage = (event) => {
    try { renderLive(JSON.parse(event.data)); } catch { /* skip frame */ }
  };
  source.onerror = () => { $("#stream-state").textContent = "reconnecting…"; };
}

/* ---------------- boot ---------------- */

$("#curve-save").addEventListener("click", () => act(async () => {
  const data = await api("/api/fan-curve", {
    profile: STATE.profile.current, fan: activeFan, points: draftCurves[activeFan],
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
}, "fan curves reset"));

(async function boot() {
  try {
    STATE = await api("/api/state");
    applyTheme(STATE.theme);
    seedDrafts();
    render();
    connectStream();
  } catch (err) {
    document.body.prepend(el("div", "note warn", `cannot reach the rog-deck service: ${err.message}`));
  }
})();
