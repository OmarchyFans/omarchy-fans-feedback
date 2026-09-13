// Omarchy Feedback viewer. Vanilla JS, no build step, no external requests.
// Data never goes into innerHTML: every string is set with textContent.
"use strict";

const TOKEN_KEY = "omarchy-feedback-token";
const S = { token: "", filter: "open", q: "", issues: [], current: null, events: [], player: null };

// ---------------------------------------------------------------- helpers --
function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === "class") el.className = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k === "text") el.textContent = v;
    else el.setAttribute(k, v === true ? "" : String(v));
  }
  for (const kid of kids.flat()) {
    if (kid === null || kid === undefined || kid === false) continue;
    el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  return el;
}
const $ = (sel, el = document) => el.querySelector(sel);

function toast(msg, ms = 4000) {
  const t = $("#toast");
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { t.hidden = true; }, ms);
}

function ago(ms) {
  const s = Math.max(0, Math.floor((Date.now() - ms) / 1000));
  if (s < 60) return s + "s ago";
  if (s < 3600) return Math.floor(s / 60) + "m ago";
  if (s < 86400) return Math.floor(s / 3600) + "h ago";
  return Math.floor(s / 86400) + "d ago";
}
function stamp(ms) { return new Date(ms).toLocaleString(); }
function rel(ms, base) {
  const d = (ms - base) / 1000, a = Math.abs(d);
  return (d < 0 ? "-" : "+") + Math.floor(a / 60) + ":" + (a % 60).toFixed(1).padStart(4, "0");
}
function safeHttp(url) { return /^https?:\/\//.test(url || "") ? url : null; }
function subjectText(i) {
  const kind = { plugin: "Plugin", app: "App", omarchy: "Omarchy", unknown: "Not sure" }[i.subject_type] || i.subject_type;
  const name = i.subject_name || i.subject_id || "";
  return kind + (name ? ": " + name : "") + (i.subject_version ? " " + i.subject_version : "");
}

// ------------------------------------------------------------------- API --
function readToken() {
  const frag = new URLSearchParams(location.hash.slice(1));
  const t = frag.get("t");
  if (t) {
    try { localStorage.setItem(TOKEN_KEY, t); } catch (e) { /* private window: keep it in memory */ }
    S.token = t;
  } else {
    try { S.token = localStorage.getItem(TOKEN_KEY) || ""; } catch (e) { S.token = ""; }
  }
  const issue = frag.get("issue");
  history.replaceState(null, "", location.pathname + (issue ? "#issue=" + encodeURIComponent(issue) : ""));
  return issue;
}

async function api(path, opts = {}) {
  const init = { method: opts.method || "GET", headers: { "X-Feedback-Token": S.token } };
  if (opts.body !== undefined) {
    init.headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(opts.body);
  }
  const r = await fetch(path, init);
  if (r.status === 401) { showConnect(); throw new Error("not connected"); }
  if (opts.raw) {
    if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || r.statusText);
    return r;
  }
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error || r.statusText);
  return data;
}

function showConnect() {
  $("#connect").hidden = false;
  $("#app").hidden = true;
}

// ------------------------------------------------------------------- list --
async function loadIssues() {
  S.issues = await api("/api/issues?status=" + encodeURIComponent(S.filter));
  renderList();
}

function renderList() {
  const ul = $("#issues");
  const q = S.q.toLowerCase();
  const rows = S.issues.filter((i) => !q || (i.title + " " + subjectText(i) + " #" + i.id).toLowerCase().includes(q));
  ul.replaceChildren(...rows.map((i) => h("li", {
    class: S.current && S.current.id === i.id ? "on" : "",
    tabindex: 0,
    onclick: () => openIssue(i.id),
    onkeydown: (e) => { if (e.key === "Enter") openIssue(i.id); },
  },
    h("span", { class: "t" }, h("span", { class: "pill " + i.status, text: i.status }), "#" + i.id + " " + (i.kind === "feature" ? "✦ " : "") + i.title),
    h("span", { class: "m", text: subjectText(i) + " · " + ago(i.created_at) + (i.attachment_kinds.includes("replay") ? " · replay" : "") }),
  )));
  $("#empty").hidden = rows.length > 0;
}

async function loadRecorder() {
  try {
    const st = await api("/api/status");
    const r = st.recorder || {};
    const live = r.running && Date.now() - r.heartbeat < 20000;
    const armed = live && r.replay && r.replay.armed;
    $("#recorder").replaceChildren(
      h("span", { class: "dot " + (armed ? "armed" : live ? "live" : "") }),
      !live ? "Recorder not running" : r.paused ? "Event log paused" : armed ? "Recording · screen replay armed" : "Recording events",
    );
  } catch (e) { /* the list call reports connection problems */ }
}

// ----------------------------------------------------------------- detail --
// Same rules as of_report.timeline: a run of hidden keystrokes is one row, repeated
// title changes keep the latest, a screenshot's capture start/stop is one row.
function tidyEvents(events) {
  const out = [];
  for (const e of events) {
    const d = e.data || {}, last = out[out.length - 1];
    if (e.type === "daemon" || d.event === "windowtitle") continue;
    if (e.type === "key" && d.redacted) {
      if (last && last.typed) { last.typed += 1; last.label = "typed " + last.typed + " keys (text hidden)"; continue; }
      out.push({ ...e, typed: 1, label: "typed 1 key (text hidden)" });
    } else if (d.retitle && last && last.data && last.data.retitle) {
      out[out.length - 1] = e;
    } else if (e.type === "screencast" && String(d.data || "").startsWith("0,") && last && last.type === "screencast"
               && String((last.data || {}).data || "").startsWith("1,") && e.t - last.t < 2000) {
      last.label = "screenshot (" + String(d.data).split(",")[1] + ")";
    } else {
      out.push(e);
    }
  }
  return out;
}

async function openIssue(id) {
  if (S.player) { S.player.stop(); S.player = null; }
  const [issue, events] = await Promise.all([api("/api/issues/" + id), api("/api/issues/" + id + "/events")]);
  S.current = issue;
  S.events = tidyEvents(events);
  history.replaceState(null, "", location.pathname + "#issue=" + id);
  renderList();
  renderDetail();
}

function att(kind) { return S.current.attachments.filter((a) => a.kind === kind); }
function images() {
  const order = { markup: 0, annotated: 1, window: 2, screenshot: 3 };
  return S.current.attachments
    .filter((a) => a.kind in order && (a.mime || "").startsWith("image/"))
    .sort((a, b) => order[a.kind] - order[b.kind] || b.id - a.id);
}
function label(a) {
  return { markup: "Markup " + (a.path.match(/\d+/) || [""])[0], annotated: "Marked up at capture", window: "Focused window", screenshot: "Full screen" }[a.kind] || a.kind;
}

function renderDetail() {
  const i = S.current;
  const d = $("#detail");
  d.replaceChildren(headCard(i), replayCard(i), shotsCard(i), textCard(i), handoffCard(i), exportCard(i));
}

function headCard(i) {
  const title = h("input", { class: "title", value: i.title, "aria-label": "Title" });
  title.addEventListener("change", () => patch({ title: title.value }));
  const status = h("select", { "aria-label": "Status", onchange: (e) => patch({ status: e.target.value }) },
    ...["new", "triaged", "sent-to-rix", "sent-to-agent", "sent-to-author", "fixed", "closed"].map((s) => h("option", { value: s, selected: s === i.status }, s)));
  const kind = h("select", { "aria-label": "Kind", onchange: (e) => patch({ kind: e.target.value }) },
    h("option", { value: "bug", selected: i.kind === "bug" }, "Bug"), h("option", { value: "feature", selected: i.kind === "feature" }, "Feature request"));
  const facts = h("dl", { class: "facts" });
  const add = (k, v) => { if (v) facts.append(h("dt", { text: k }), h("dd", {}, v)); };
  add("About", subjectText(i));
  if (i.author) add("Author", i.author);
  const repo = safeHttp(i.repo_url);
  if (repo) add("Project", h("a", { href: repo, target: "_blank", rel: "noopener noreferrer", text: repo }));
  const win = (i.context || {}).activewindow || {};
  if (win.class) add("Focused window", win.class + (win.title ? " — " + win.title : ""));
  const env = (i.context || {}).env || {};
  add("Omarchy", env.omarchy); add("Hyprland", env.hyprland); add("Theme", env.theme);
  add("Reported", stamp(i.created_at) + " (" + ago(i.created_at) + ") via " + (i.source || "capture"));
  return h("div", { class: "card head" }, title, h("div", { class: "row" }, h("span", { class: "muted", text: "#" + i.id }), kind, status), facts);
}

async function patch(body) {
  try {
    S.current = await api("/api/issues/" + S.current.id, { method: "PATCH", body });
    toast("Saved");
    await loadIssues();
  } catch (e) { toast("Could not save: " + e.message); }
}

// ---- replay: the video with its timeline, or a step-through over the screenshot
function replayCard(i) {
  const card = h("div", { class: "card" }, h("h2", { text: "Leading up to the report" }));
  const replay = att("replay")[0];
  const base = i.capture_t_ms || (S.events.length ? S.events[S.events.length - 1].t : Date.now());
  const list = h("ol", { class: "timeline", "aria-label": "Timeline" });
  const items = S.events.map((e) => {
    const li = h("li", { class: e.type === "mark" ? "mark" : "" }, h("span", { class: "when", text: rel(e.t, base) }), h("span", { text: e.label }));
    list.append(li);
    return li;
  });
  if (!S.events.length) list.append(h("li", {}, h("span", {}), h("span", { class: "muted", text: "No events were recorded (the recorder was off or paused)." })));

  const stage = h("div", { class: "stage" });
  const wrap = h("div", {}, stage);
  let player;
  if (replay) {
    player = videoPlayer(stage, wrap, replay, items);
    card.append(h("p", { class: "muted", text: "Screen replay of the last moments before the capture. Events outside the replay are dimmed; click one to jump to it." }));
  } else {
    player = stepPlayer(stage, wrap, i, items, base);
    card.append(h("p", { class: "muted", text: "No screen replay was armed, so this steps through the recorded events over the screenshot: focus changes, shortcuts and where the pointer was." }));
  }
  S.player = player;
  card.append(h("div", { class: "replay" }, wrap, list));
  return card;
}

function highlight(items, idx) {
  items.forEach((li, n) => li.classList.toggle("now", n === idx));
  // Scroll only the list, never the page, while the video plays.
  const li = items[idx], box = li && li.parentElement;
  if (!box) return;
  const top = li.offsetTop - box.offsetTop;
  if (top < box.scrollTop || top + li.offsetHeight > box.scrollTop + box.clientHeight) box.scrollTop = top - box.clientHeight / 3;
}

function videoPlayer(stage, wrap, replay, items) {
  const first = replay.meta && replay.meta.firstFrameMs;
  const video = h("video", { src: replay.url, controls: true, preload: "metadata", playsinline: true });
  stage.append(video);
  const lastIndexAt = (wall) => { let idx = -1; S.events.forEach((e, n) => { if (e.t <= wall) idx = n; }); return idx; };
  const mark = () => {
    if (!first || !isFinite(video.duration)) return;
    const end = first + video.duration * 1000;
    S.events.forEach((e, n) => items[n] && items[n].classList.toggle("out", e.t < first || e.t > end + 1000));
    const k = S.events.findIndex((e) => e.t >= first);
    const li = items[k], box = li && li.parentElement;
    if (box) box.scrollTop = li.offsetTop - box.offsetTop;
  };
  video.addEventListener("loadedmetadata", mark);
  video.addEventListener("timeupdate", () => { if (first) highlight(items, lastIndexAt(first + video.currentTime * 1000)); });
  items.forEach((li, n) => li.addEventListener("click", () => {
    if (!first) return;
    const at = (S.events[n].t - first) / 1000;
    if (at >= 0 && (!isFinite(video.duration) || at <= video.duration)) { video.currentTime = at; video.play().catch(() => {}); }
    else toast("That event happened before the replay started.");
  }));
  if (!first) wrap.append(h("p", { class: "muted", text: "This replay has no start timestamp, so the timeline cannot follow the video." }));
  else if (replay.meta.estimated) wrap.append(h("p", { class: "muted", text: "Timeline sync is approximate (within about a second)." }));
  return { stop() { video.pause(); } };
}

function stepPlayer(stage, wrap, i, items, base) {
  const img = images().find((a) => a.kind === "annotated") || images().find((a) => a.kind === "screenshot");
  const caption = h("div", { class: "caption", text: "Press play to step through what happened." });
  const cursor = h("div", { class: "cursor", hidden: true });
  const keycap = h("div", { class: "keycap", hidden: true });
  if (img) stage.append(h("img", { src: img.url, alt: "Screenshot at the time of the report" }));
  else stage.append(h("div", { class: "empty", text: "No screenshot was taken." }));
  stage.append(cursor, keycap, caption);

  const env = (i.context || {}).env || {};
  const mon = (env.monitors || []).find((m) => m.name === i.monitor) || (env.monitors || [])[0] || null;
  const steps = S.events.map((e, n) => ({ e, n })).filter(({ e }) => ["window", "layer", "key", "workspace", "monitor", "cursor", "lock", "mark", "submap"].includes(e.type));
  let pos = -1, timer = null;
  const slider = h("input", { type: "range", min: 0, max: Math.max(0, steps.length - 1), value: 0, "aria-label": "Step" });
  const playBtn = h("button", { class: "btn", type: "button", text: "Play" });

  function show(k) {
    pos = Math.max(0, Math.min(k, steps.length - 1));
    if (!steps.length) return;
    const { e, n } = steps[pos];
    slider.value = pos;
    caption.textContent = rel(e.t, base) + "  " + e.label;
    highlight(items, n);
    keycap.hidden = e.type !== "key";
    if (e.type === "key") keycap.textContent = e.data.combo || "";
    if (e.type === "cursor" && mon && stage.firstChild && stage.firstChild.naturalWidth) {
      const im = stage.firstChild;
      const px = (e.data.x - (mon.x || 0)) * (mon.scale || 1), py = (e.data.y - (mon.y || 0)) * (mon.scale || 1);
      cursor.style.left = (px / im.naturalWidth * 100) + "%";
      cursor.style.top = (py / im.naturalHeight * 100) + "%";
      cursor.hidden = false;
    }
  }
  function stop() { clearTimeout(timer); timer = null; playBtn.textContent = "Play"; }
  function tick() {
    if (pos >= steps.length - 1) { stop(); return; }
    const gap = pos >= 0 ? steps[pos + 1].e.t - steps[pos].e.t : 0;
    show(pos + 1);
    timer = setTimeout(tick, Math.max(350, Math.min(1400, gap)));
  }
  playBtn.addEventListener("click", () => {
    if (timer) { stop(); return; }
    if (pos >= steps.length - 1) pos = -1;
    playBtn.textContent = "Pause";
    tick();
  });
  slider.addEventListener("input", () => { stop(); show(Number(slider.value)); });
  items.forEach((li, n) => li.addEventListener("click", () => {
    const k = steps.findIndex((s) => s.n === n);
    if (k >= 0) { stop(); show(k); }
  }));
  wrap.append(h("div", { class: "controls" },
    h("button", { class: "btn", type: "button", text: "◀", "aria-label": "Previous", onclick: () => { stop(); show(pos - 1); } }),
    playBtn,
    h("button", { class: "btn", type: "button", text: "▶", "aria-label": "Next", onclick: () => { stop(); show(pos + 1); } }),
    slider));
  return { stop };
}

// ---- screenshots and markup
function shotsCard(i) {
  const card = h("div", { class: "card shots" }, h("h2", { text: "Screenshots and markup" }));
  const imgs = images();
  if (!imgs.length) { card.append(h("p", { class: "muted", text: "No screenshots." })); return card; }
  let sel = imgs[0];
  const tabs = h("div", { class: "tabs" });
  const view = h("div", { class: "shot" });
  function select(a) {
    sel = a;
    tabs.querySelectorAll(".btn").forEach((b) => b.classList.toggle("on", b.dataset.id === String(a.id)));
    view.replaceChildren(h("img", { src: a.url, alt: label(a) }));
  }
  imgs.forEach((a) => tabs.append(h("button", { class: "btn", type: "button", "data-id": a.id, text: label(a), onclick: () => select(a) })));
  tabs.append(h("button", { class: "btn primary", type: "button", text: "Mark up", onclick: () => editor(card, sel) }));
  card.append(tabs, view);
  select(sel);
  return card;
}

function editor(card, base) {
  const colors = ["#ff5345", "#e5c736", "#2dd5b7", "#7aa2f7", "#ffffff", "#000000"];
  const st = { tool: "arrow", color: colors[0], width: 6, shapes: [], redo: [], drag: null };
  const img = new Image();
  const canvas = h("canvas", { "aria-label": "Markup canvas" });
  const ctx = canvas.getContext("2d");
  const toolBtns = {};
  const bar = h("div", { class: "toolbar" });
  for (const [tool, name] of [["pen", "Pen"], ["arrow", "Arrow"], ["rect", "Box"], ["text", "Text"]]) {
    toolBtns[tool] = h("button", { class: "btn", type: "button", text: name, onclick: () => { st.tool = tool; paintBar(); } });
    bar.append(toolBtns[tool]);
  }
  const swatches = colors.map((c) => {
    const b = h("button", { class: "swatch", type: "button", "aria-label": "Colour " + c, onclick: () => { st.color = c; paintBar(); } });
    b.style.background = c;
    bar.append(b);
    return b;
  });
  const width = h("input", { type: "range", min: 2, max: 24, value: st.width, "aria-label": "Line width", oninput: (e) => { st.width = Number(e.target.value); } });
  bar.append(width,
    h("button", { class: "btn", type: "button", text: "Undo", onclick: () => { if (st.shapes.length) st.redo.push(st.shapes.pop()); draw(); } }),
    h("button", { class: "btn", type: "button", text: "Redo", onclick: () => { if (st.redo.length) st.shapes.push(st.redo.pop()); draw(); } }),
    h("button", { class: "btn", type: "button", text: "Clear", onclick: () => { st.redo = st.shapes.splice(0).reverse(); draw(); } }),
    h("button", { class: "btn primary", type: "button", text: "Save markup", onclick: save }),
    h("button", { class: "btn", type: "button", text: "Cancel", onclick: () => renderDetail() }));
  function paintBar() {
    Object.entries(toolBtns).forEach(([t, b]) => b.classList.toggle("on", t === st.tool));
    swatches.forEach((b, n) => b.classList.toggle("on", colors[n] === st.color));
  }
  paintBar();

  function point(ev) {
    const r = canvas.getBoundingClientRect();
    return [(ev.clientX - r.left) * canvas.width / r.width, (ev.clientY - r.top) * canvas.height / r.height];
  }
  function drawShape(s) {
    ctx.strokeStyle = s.color; ctx.fillStyle = s.color; ctx.lineWidth = s.width; ctx.lineCap = "round"; ctx.lineJoin = "round";
    if (s.type === "pen") {
      ctx.beginPath();
      s.points.forEach(([x, y], n) => (n ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
      ctx.stroke();
    } else if (s.type === "rect") {
      ctx.strokeRect(Math.min(s.x1, s.x2), Math.min(s.y1, s.y2), Math.abs(s.x2 - s.x1), Math.abs(s.y2 - s.y1));
    } else if (s.type === "arrow") {
      const a = Math.atan2(s.y2 - s.y1, s.x2 - s.x1), head = Math.max(14, s.width * 3.2);
      ctx.beginPath(); ctx.moveTo(s.x1, s.y1); ctx.lineTo(s.x2, s.y2); ctx.stroke();
      ctx.beginPath();
      ctx.moveTo(s.x2, s.y2);
      ctx.lineTo(s.x2 - head * Math.cos(a - Math.PI / 7), s.y2 - head * Math.sin(a - Math.PI / 7));
      ctx.lineTo(s.x2 - head * Math.cos(a + Math.PI / 7), s.y2 - head * Math.sin(a + Math.PI / 7));
      ctx.closePath(); ctx.fill();
    } else if (s.type === "text") {
      const size = Math.max(16, s.width * 4);
      ctx.font = "700 " + size + "px system-ui, sans-serif";
      const w = ctx.measureText(s.text).width;
      ctx.fillStyle = "rgba(0,0,0,.72)";
      ctx.fillRect(s.x - 6, s.y - size, w + 12, size * 1.35);
      ctx.fillStyle = s.color;
      ctx.fillText(s.text, s.x, s.y);
    }
  }
  function draw() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(img, 0, 0);
    st.shapes.forEach(drawShape);
    if (st.drag) drawShape(st.drag);
  }
  canvas.addEventListener("pointerdown", (ev) => {
    const [x, y] = point(ev);
    if (st.tool === "text") {
      const text = (window.prompt("Note to place on the screenshot:") || "").trim();
      if (text) { st.shapes.push({ type: "text", color: st.color, width: st.width, x, y, text: text.slice(0, 300) }); st.redo = []; draw(); }
      return;
    }
    canvas.setPointerCapture(ev.pointerId);
    st.drag = st.tool === "pen" ? { type: "pen", color: st.color, width: st.width, points: [[x, y]] }
      : { type: st.tool, color: st.color, width: st.width, x1: x, y1: y, x2: x, y2: y };
  });
  canvas.addEventListener("pointermove", (ev) => {
    if (!st.drag) return;
    const [x, y] = point(ev);
    if (st.drag.type === "pen") st.drag.points.push([x, y]); else { st.drag.x2 = x; st.drag.y2 = y; }
    draw();
  });
  canvas.addEventListener("pointerup", () => {
    if (!st.drag) return;
    const s = st.drag; st.drag = null;
    if (s.type === "pen" ? s.points.length > 1 : Math.hypot(s.x2 - s.x1, s.y2 - s.y1) > 4) { st.shapes.push(s); st.redo = []; }
    draw();
  });

  async function save() {
    if (!st.shapes.length) { toast("Draw something first."); return; }
    try {
      S.current = await api("/api/issues/" + S.current.id + "/markup", {
        method: "POST", body: { base: base.path, shapes: st.shapes, png: canvas.toDataURL("image/png") },
      });
      toast("Markup saved");
      renderDetail();
    } catch (e) { toast("Could not save the markup: " + e.message); }
  }

  img.onload = () => { canvas.width = img.naturalWidth; canvas.height = img.naturalHeight; draw(); };
  img.src = base.url;
  card.replaceChildren(h("h2", { text: "Mark up: " + label(base) }), bar, h("div", { class: "editor" }, canvas));
}

// ---- words, hand-offs, export
function textCard(i) {
  const desc = h("textarea", { "aria-label": "What happened" }, i.description || "");
  const notes = h("textarea", { "aria-label": "Notes", placeholder: "Your notes, findings, what an agent should know…" }, i.notes || "");
  return h("div", { class: "card" }, h("h2", { text: "What happened" }), desc,
    h("h2", { text: "Notes" }), notes,
    h("div", { class: "row" }, h("button", { class: "btn primary", type: "button", text: "Save text", onclick: () => patch({ description: desc.value, notes: notes.value }) })));
}

function handoffCard(i) {
  const req = async (target, words) => {
    try {
      await api("/api/issues/" + i.id + "/handoff", { method: "POST", body: { target } });
      toast("Confirm on your desktop: a notification asks before anything is sent to " + words + ".", 7000);
      S.current = await api("/api/issues/" + i.id);
      renderDetail();
    } catch (e) { toast("Could not request the hand-off: " + e.message); }
  };
  const list = h("ul", { class: "handoffs" }, ...(i.handoffs || []).map((x) =>
    h("li", { text: stamp(x.created_at) + " → " + x.target + " · " + x.status + (x.result_ref ? " · " + x.result_ref : "") })));
  return h("div", { class: "card" }, h("h2", { text: "Hand off" }),
    h("p", { class: "muted", text: "The viewer only asks; your desktop confirms each hand-off before an agent starts or anything opens." }),
    h("div", { class: "row" },
      h("button", { class: "btn", type: "button", text: "Send to Rix", onclick: () => req("rix", "Rix") }),
      h("button", { class: "btn", type: "button", text: "Send to coding agent", onclick: () => req("agent", "your coding agent") }),
      h("button", { class: "btn", type: "button", text: "Send to author", disabled: !safeHttp(i.repo_url), onclick: () => req("author", "the author") })),
    list);
}

function exportCard(i) {
  const download = async (kind) => {
    try {
      toast(kind === "pdf" ? "Rendering the PDF…" : "Preparing Markdown…", 10000);
      const r = await api("/api/issues/" + i.id + "/export." + kind, { raw: true });
      const blob = await r.blob();
      const a = h("a", { href: URL.createObjectURL(blob), download: "feedback-" + i.id + "." + kind });
      document.body.append(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(a.href), 30000);
      toast("Downloaded feedback-" + i.id + "." + kind);
    } catch (e) { toast("Export failed: " + e.message); }
  };
  return h("div", { class: "card" }, h("h2", { text: "Export" }),
    h("div", { class: "row" },
      h("button", { class: "btn", type: "button", text: "Download Markdown", onclick: () => download("md") }),
      h("button", { class: "btn", type: "button", text: "Download PDF", onclick: () => download("pdf") })));
}

// ------------------------------------------------------------------ start --
async function start() {
  const wanted = readToken();
  if (!S.token) { showConnect(); return; }
  document.querySelectorAll(".seg button").forEach((b) => b.addEventListener("click", async () => {
    document.querySelectorAll(".seg button").forEach((x) => x.classList.toggle("on", x === b));
    S.filter = b.dataset.filter;
    await loadIssues();
  }));
  $("#search").addEventListener("input", (e) => { S.q = e.target.value; renderList(); });
  try {
    await loadIssues();
  } catch (e) {
    if (e.message !== "not connected") toast("Could not load issues: " + e.message);
    return;
  }
  $("#connect").hidden = true;
  $("#app").hidden = false;
  loadRecorder();
  setInterval(loadRecorder, 10000);
  setInterval(() => loadIssues().catch(() => {}), 15000);
  const fromHash = wanted || new URLSearchParams(location.hash.slice(1)).get("issue");
  const first = fromHash ? Number(fromHash) : (S.issues[0] && S.issues[0].id);
  if (first) openIssue(first).catch((e) => toast("Could not open #" + first + ": " + e.message));
  if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});
}

start();
