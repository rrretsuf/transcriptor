const LANGUAGES = {
  sl: "Slovenian", en: "English", de: "German", it: "Italian", hr: "Croatian",
  sr: "Serbian", bs: "Bosnian", fr: "French", es: "Spanish", pt: "Portuguese",
  nl: "Dutch", pl: "Polish", cs: "Czech", sk: "Slovak", hu: "Hungarian",
  ro: "Romanian", bg: "Bulgarian", ru: "Russian", uk: "Ukrainian", tr: "Turkish",
  el: "Greek", ar: "Arabic", he: "Hebrew", hi: "Hindi", zh: "Chinese",
  ja: "Japanese", ko: "Korean", sv: "Swedish", da: "Danish", fi: "Finnish", no: "Norwegian",
};

const $ = (id) => document.getElementById(id);
const savedEl = $("saved");
let config = null;
let saveTimer = null;

/* ---------------------------------- saving --------------------------------- */

function save(patch) {
  config = { ...config, ...patch };
  clearTimeout(saveTimer);
  saveTimer = setTimeout(async () => {
    await window.flow.setConfig(patch);
    savedEl.textContent = "Saved";
    savedEl.classList.add("flash");
    setTimeout(() => {
      savedEl.classList.remove("flash");
      savedEl.textContent = "Voice dictation anywhere on your Mac";
    }, 1200);
  }, 250);
}

/* --------------------------------- languages -------------------------------- */

function renderLanguages() {
  const host = $("languages");
  host.innerHTML = "";
  for (const [code, name] of Object.entries(LANGUAGES)) {
    const chip = document.createElement("button");
    chip.type = "button";
    chip.className = "chip";
    chip.textContent = name;
    chip.setAttribute("aria-pressed", String(config.languageHints.includes(code)));
    chip.onclick = () => {
      const on = chip.getAttribute("aria-pressed") === "true";
      chip.setAttribute("aria-pressed", String(!on));
      const next = on
        ? config.languageHints.filter((c) => c !== code)
        : [...config.languageHints, code];
      save({ languageHints: next });
    };
    host.appendChild(chip);
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
    field.value = config.hotkey;
    field.blur();
  };
  field.onclick = () => {
    field.classList.add("capturing");
    field.value = "Press keys…";
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
    $("hotkeyEcho").textContent = combo;
    stop();
  };
}

/* -------------------------------- permissions ------------------------------- */

async function refreshPermissions() {
  const status = await window.flow.permStatus();

  const micGranted = status.microphone === "granted";
  $("micBtn").textContent = micGranted ? "Granted" : "Grant";
  $("micBtn").disabled = micGranted;
  $("micBtn").classList.toggle("granted", micGranted);
  $("micNote").textContent = micGranted
    ? "Soniox Flow can record your voice."
    : "Required to record your voice.";

  const axGranted = status.accessibility;
  $("axBtn").textContent = axGranted ? "Granted" : "Grant";
  $("axBtn").disabled = axGranted;
  $("axBtn").classList.toggle("granted", axGranted);
  $("axNote").textContent = axGranted
    ? "Soniox Flow can paste at the cursor."
    : "Required to paste at the cursor. Restart the app after granting.";
}

/* ----------------------------------- key ------------------------------------ */

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

  const result = await window.flow.verifyKey(key);
  $("verify").disabled = false;

  if (!result.ok) {
    status.className = "note bad";
    status.textContent = `Key rejected — ${result.message}`;
    return;
  }
  status.className = "note ok";
  status.textContent = "Key works. Stored encrypted in your macOS Keychain.";

  if (result.models?.length) {
    const select = $("model");
    select.innerHTML = "";
    for (const id of result.models) {
      const option = new Option(id, id, false, id === config.model);
      select.add(option);
    }
    if (!result.models.includes(config.model)) save({ model: result.models[0] });
  }
}

/* ----------------------------------- boot ----------------------------------- */

(async () => {
  config = await window.flow.getConfig();

  $("apiKey").value = config.apiKey || "";
  $("model").value = config.model;
  $("translateTo").value = config.translateTo || "";
  $("context").value = config.context || "";
  $("hotkey").value = config.hotkey;
  $("hotkeyEcho").textContent = config.hotkey;
  $("silenceStopMs").value = String(config.silenceStopMs);
  $("autoPaste").checked = config.autoPaste;
  $("restoreClipboard").checked = config.restoreClipboard;
  $("launchAtLogin").checked = config.launchAtLogin;

  renderLanguages();
  bindHotkey();
  refreshPermissions();

  $("apiKey").oninput = (e) => save({ apiKey: e.target.value.trim() });
  $("model").onchange = (e) => save({ model: e.target.value });
  $("translateTo").onchange = (e) => save({ translateTo: e.target.value });
  $("context").oninput = (e) => save({ context: e.target.value });
  $("silenceStopMs").onchange = (e) => save({ silenceStopMs: Number(e.target.value) });
  $("autoPaste").onchange = (e) => save({ autoPaste: e.target.checked });
  $("restoreClipboard").onchange = (e) => save({ restoreClipboard: e.target.checked });
  $("launchAtLogin").onchange = (e) => save({ launchAtLogin: e.target.checked });

  $("verify").onclick = verifyKey;
  $("micBtn").onclick = async () => { await window.flow.askMicrophone(); refreshPermissions(); };
  $("axBtn").onclick = async () => { await window.flow.askAccessibility(); };

  window.addEventListener("focus", refreshPermissions);
})();
