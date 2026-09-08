const LANGUAGES = {
  sl: "Slovenian", en: "English", de: "German", it: "Italian", hr: "Croatian",
  sr: "Serbian", bs: "Bosnian", fr: "French", es: "Spanish", pt: "Portuguese",
  nl: "Dutch", pl: "Polish", cs: "Czech", sk: "Slovak", hu: "Hungarian",
  ro: "Romanian", bg: "Bulgarian", ru: "Russian", uk: "Ukrainian", tr: "Turkish",
  el: "Greek", ar: "Arabic", he: "Hebrew", hi: "Hindi", zh: "Chinese",
  ja: "Japanese", ko: "Korean", sv: "Swedish", da: "Danish", fi: "Finnish", no: "Norwegian",
};

const KEY_SYMBOLS = { Command: "⌘", Control: "⌃", Alt: "⌥", Shift: "⇧" };
const pretty = (accelerator) =>
  accelerator.split("+").map((part) => KEY_SYMBOLS[part] ?? part).join("");

const $ = (id) => document.getElementById(id);
const sub = $("sub");
let config = null;
let saveTimer = null;

function save(patch) {
  config = { ...config, ...patch };
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => window.app.setConfig(patch), 200);
}

/* ----------------------------------- usage ---------------------------------- */

function sparkline(values) {
  const max = Math.max(...values);
  if (max <= 0) return null;
  const step = 132 / Math.max(1, values.length - 1);
  return values
    .map((v, i) => `${i ? "L" : "M"}${(i * step).toFixed(1)},${(34 - (v / max) * 30).toFixed(1)}`)
    .join(" ");
}

async function renderUsage() {
  const [usage, local] = await Promise.all([window.app.usage(30), window.app.localStats()]);

  $("lCount").textContent = local.count.toLocaleString();
  $("lWords").textContent = local.words.toLocaleString();

  if (!usage.ok) {
    $("uCost").textContent = "—";
    $("uCap").textContent = `Soniox usage unavailable — ${usage.message}`;
    $("tiles").classList.remove("loading");
    return;
  }

  $("uCost").textContent = usage.costUsd < 0.01 && usage.costUsd > 0
    ? `$${usage.costUsd.toFixed(4)}`
    : `$${usage.costUsd.toFixed(2)}`;
  $("uCap").textContent = usage.requests
    ? "Last 30 days on Soniox"
    : "No Soniox usage recorded in the last 30 days";
  $("uReq").textContent = usage.requests.toLocaleString();
  $("uMin").textContent = Math.round(usage.audioMs / 60000).toLocaleString();
  $("tiles").classList.remove("loading");

  const path = sparkline(usage.dailyCost);
  if (path) {
    $("spark").hidden = false;
    $("spark").querySelector("path").setAttribute("d", path);
  }
}

/* --------------------------------- languages -------------------------------- */

function renderLanguages() {
  const host = $("languages");
  const picker = $("addLanguage");
  const chosen = config.languageHints.filter((code) => LANGUAGES[code]);

  host.innerHTML = "";
  for (const code of chosen) {
    const token = document.createElement("button");
    token.type = "button";
    token.className = "chip";
    token.setAttribute("aria-pressed", "true");
    token.innerHTML = `${LANGUAGES[code]}<span class="x">\u00d7</span>`;
    token.title = "Remove";
    token.onclick = () => {
      save({ languageHints: chosen.filter((c) => c !== code) });
      renderLanguages();
    };
    host.appendChild(token);
  }

  picker.innerHTML = "";
  picker.add(new Option(chosen.length ? "Add language" : "Add language", ""));
  for (const [code, name] of Object.entries(LANGUAGES)) {
    if (!chosen.includes(code)) picker.add(new Option(name, code));
  }
  picker.onchange = () => {
    if (!picker.value) return;
    save({ languageHints: [...chosen, picker.value] });
    renderLanguages();
  };

  $("langNote").textContent = chosen.length
    ? "Soniox listens for these first."
    : "Automatic — Soniox detects the language on its own.";
}

function renderPosition() {
  for (const chip of $("position").children) {
    chip.setAttribute("aria-pressed", String(chip.dataset.value === config.position));
    chip.onclick = () => {
      save({ position: chip.dataset.value });
      renderPosition();
    };
  }
}

/* ---------------------------------- hotkey ---------------------------------- */

const KEY_ALIASES = {
  Space: "Space", Enter: "Return", Tab: "Tab", Backspace: "Backspace",
  ArrowUp: "Up", ArrowDown: "Down", ArrowLeft: "Left", ArrowRight: "Right",
  Comma: ",", Period: ".", Slash: "/", Backslash: "\\", Semicolon: ";",
  Quote: "'", BracketLeft: "[", BracketRight: "]", Minus: "-", Equal: "=", Backquote: "`",
};

function accelerator(event) {
  const code = event.code;
  let key = null;
  if (/^Key[A-Z]$/.test(code)) key = code.slice(3);
  else if (/^Digit\d$/.test(code)) key = code.slice(5);
  else if (/^F\d{1,2}$/.test(code)) key = code;
  else key = KEY_ALIASES[code] ?? null;
  if (!key) return null;

  const parts = [];
  if (event.metaKey) parts.push("Command");
  if (event.ctrlKey) parts.push("Control");
  if (event.altKey) parts.push("Alt");
  if (event.shiftKey) parts.push("Shift");
  if (!parts.length && !/^F\d{1,2}$/.test(key)) return null;
  parts.push(key);
  return parts.join("+");
}

function bindHotkey() {
  const field = $("hotkey");
  const stop = () => {
    field.classList.remove("capturing");
    field.value = pretty(config.hotkey);
    field.blur();
  };
  field.onclick = () => {
    field.classList.add("capturing");
    field.value = "Press keys";
    field.focus();
  };
  field.onblur = stop;
  field.onkeydown = (event) => {
    if (!field.classList.contains("capturing")) return;
    event.preventDefault();
    if (event.code === "Escape") return stop();
    const combo = accelerator(event);
    if (!combo) return;
    save({ hotkey: combo });
    $("hotkeyEcho").textContent = pretty(combo);
    stop();
  };
}

/* -------------------------------- permissions ------------------------------- */

async function refreshPermissions() {
  const status = await window.app.permStatus();

  const mic = status.microphone === "granted";
  $("micBtn").textContent = mic ? "Granted" : "Grant";
  $("micBtn").disabled = mic;
  $("micBtn").classList.toggle("done", mic);
  $("micNote").textContent = mic
    ? "Transcriber can record your voice."
    : "Required to record your voice.";

  const ax = status.accessibility;
  $("axBtn").textContent = ax ? "Granted" : "Grant";
  $("axBtn").disabled = ax;
  $("axBtn").classList.toggle("done", ax);
  $("axNote").textContent = ax
    ? "Transcriber can paste at the cursor."
    : "Required to paste at the cursor. Restart after granting.";
}

/* ------------------------------------ key ----------------------------------- */

async function verifyKey() {
  const key = $("apiKey").value.trim();
  const status = $("keyStatus");
  if (!key) {
    status.className = "note bad";
    status.textContent = "Paste your Soniox API key first.";
    return;
  }
  $("verify").disabled = true;
  status.className = "note";
  status.textContent = "Checking…";

  const result = await window.app.verifyKey(key);
  $("verify").disabled = false;

  if (!result.ok) {
    status.className = "note bad";
    status.textContent = `Key rejected — ${result.message}`;
    return;
  }
  status.className = "note ok";
  status.textContent = "Key works. Encrypted in your macOS Keychain.";

  if (result.models?.length) {
    const select = $("model");
    select.innerHTML = "";
    for (const id of result.models) select.add(new Option(id, id, false, id === config.model));
    if (!result.models.includes(config.model)) save({ model: result.models[0] });
  }
  renderUsage();
}

/* ----------------------------------- boot ----------------------------------- */

(async () => {
  config = await window.app.getConfig();

  $("apiKey").value = config.apiKey || "";
  $("model").value = config.model;
  $("translateTo").value = config.translateTo || "";
  $("context").value = config.context || "";
  $("hotkey").value = pretty(config.hotkey);
  $("hotkeyEcho").textContent = pretty(config.hotkey);
  $("silenceStopMs").value = String(config.silenceStopMs);
  $("autoPaste").checked = config.autoPaste;
  $("restoreClipboard").checked = config.restoreClipboard;
  $("saveHistory").checked = config.saveHistory;
  $("launchAtLogin").checked = config.launchAtLogin;

  renderLanguages();
  renderPosition();
  bindHotkey();
  refreshPermissions();
  renderUsage();

  $("apiKey").oninput = (e) => save({ apiKey: e.target.value.trim() });
  $("model").onchange = (e) => save({ model: e.target.value });
  $("translateTo").onchange = (e) => save({ translateTo: e.target.value });
  $("context").oninput = (e) => save({ context: e.target.value });
  $("silenceStopMs").onchange = (e) => save({ silenceStopMs: Number(e.target.value) });
  $("autoPaste").onchange = (e) => save({ autoPaste: e.target.checked });
  $("restoreClipboard").onchange = (e) => save({ restoreClipboard: e.target.checked });
  $("saveHistory").onchange = (e) => save({ saveHistory: e.target.checked });
  $("launchAtLogin").onchange = (e) => save({ launchAtLogin: e.target.checked });

  $("verify").onclick = verifyKey;
  $("console").onclick = () => window.app.openConsole();
  $("micBtn").onclick = async () => { await window.app.askMicrophone(); refreshPermissions(); };
  $("axBtn").onclick = () => window.app.askAccessibility();

  window.addEventListener("focus", refreshPermissions);
})();
