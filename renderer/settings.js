const LANGUAGES = {
  sl: "Slovenian", en: "English", de: "German", it: "Italian", hr: "Croatian",
  sr: "Serbian", bs: "Bosnian", fr: "French", es: "Spanish", pt: "Portuguese",
  nl: "Dutch", pl: "Polish", cs: "Czech", sk: "Slovak", hu: "Hungarian",
  ro: "Romanian", bg: "Bulgarian", ru: "Russian", uk: "Ukrainian", tr: "Turkish",
  el: "Greek", ar: "Arabic", he: "Hebrew", hi: "Hindi", zh: "Chinese",
  ja: "Japanese", ko: "Korean", sv: "Swedish", da: "Danish", fi: "Finnish", no: "Norwegian",
};

const $ = (id) => document.getElementById(id);

// Every keystroke would otherwise re-encrypt the key and rewrite settings to disk.
const debounce = (fn, ms) => {
  let timer = null;
  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), ms);
  };
};
let config = null;
let savedConfig = null;
let saveId = 0;
const pendingSaves = new Map();
let usageRequest = 0;
let oUsageRequest = 0;
let usageUpdatedAt = 0;

function showSaveError(message = "") {
  $("saveStatus").textContent = message;
  $("saveStatus").hidden = !message;
}

async function save(patch) {
  const id = ++saveId;
  pendingSaves.set(id, patch);
  config = { ...config, ...patch };
  try {
    await window.app.setConfig(patch);
    Object.assign(savedConfig, patch);
    pendingSaves.delete(id);
    showSaveError();
    return true;
  } catch (err) {
    pendingSaves.delete(id);
    config = Object.assign({}, savedConfig, ...pendingSaves.values());
    for (const key of Object.keys(patch)) {
      const field = $(key);
      if (field?.type === "checkbox") field.checked = config[key];
      else if (field && "value" in field) field.value = config[key];
    }
    renderLanguages();
    renderPosition();
    renderCleanupTier();
    showSaveError(err.message.replace(/^Error invoking remote method '[^']+': Error: /, ""));
    return false;
  }
}

function setSelectValue(id, value) {
  const field = $(id);
  if (![...field.options].some(option => option.value === value)) field.add(new Option(value, value));
  field.value = value;
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

async function renderLocalStats() {
  try {
    const local = await window.app.localStats();
    $("lCount").textContent = local.count.toLocaleString();
    $("lWords").textContent = local.words.toLocaleString();
  } catch {
    $("lCount").textContent = "—";
    $("lWords").textContent = "—";
  }
}

function formatCost(usd) {
  return usd < 0.01 && usd > 0 ? `$${usd.toFixed(4)}` : `$${usd.toFixed(2)}`;
}

// Total = Soniox (last 30 days, server-side) + OpenRouter cleanup (this Mac).
let sonioxCost = null;
let routerCost = null;

function renderTotal() {
  $("uTotal").textContent = sonioxCost == null && routerCost == null
    ? "—"
    : formatCost((sonioxCost || 0) + (routerCost || 0));
}

async function renderUsage() {
  const request = ++usageRequest;
  usageUpdatedAt = Date.now();
  let usage;
  try { usage = await window.app.usage(30); }
  catch (err) { usage = { ok: false, message: err.message }; }
  if (request !== usageRequest) return;
  $("tiles").classList.remove("loading");
  $("spark").setAttribute("hidden", "");
  if (!usage.ok) {
    sonioxCost = null;
    $("uSoniox").textContent = "—";
    $("uReq").textContent = "—";
    $("uMin").textContent = "—";
    $("uCap").textContent = `Soniox usage unavailable — ${usage.message}`;
    renderTotal();
    return;
  }
  sonioxCost = usage.costUsd;
  $("uSoniox").textContent = formatCost(usage.costUsd);
  $("uCap").textContent = usage.requests
    ? "Soniox last 30 days + cleanup on this Mac"
    : "No Soniox usage in the last 30 days — total is cleanup spend";
  $("uReq").textContent = usage.requests.toLocaleString();
  $("uMin").textContent = Math.round(usage.audioMs / 60000).toLocaleString();
  const path = sparkline(usage.dailyCost);
  if (path) {
    $("spark").removeAttribute("hidden");
    $("spark").querySelector("path").setAttribute("d", path);
  }
  renderTotal();
}

async function renderOpenrouterUsage() {
  const request = ++oUsageRequest;
  let usage;
  try { usage = await window.app.usageOpenrouter(); }
  catch (err) { usage = { ok: false, message: err.message, local: { count: 0, promptTokens: 0, completionTokens: 0, costUsd: 0 } }; }
  if (request !== oUsageRequest) return;
  const local = usage.local || { count: 0, promptTokens: 0, completionTokens: 0, costUsd: 0 };
  routerCost = local.costUsd || 0;
  $("uRouter").textContent = formatCost(routerCost);
  $("oCount").textContent = (local.count || 0).toLocaleString();
  $("oTokens").textContent = ((local.promptTokens || 0) + (local.completionTokens || 0)).toLocaleString();
  $("oKeyNote").textContent = !usage.ok
    ? `Generations, costs and limits live there. Key usage unavailable — ${usage.message}`
    : usage.keyLimit == null
      ? `Key usage ${formatCost(usage.keyUsage || 0)}, no limit set — full activity lives there.`
      : `Key usage ${formatCost(usage.keyUsage || 0)} of ${formatCost(usage.keyLimit)} limit — full activity lives there.`;
  renderTotal();
}

function renderLanguages() {
  const host = $("languages");
  const picker = $("addLanguage");
  const chosen = config.languageHints;

  host.innerHTML = "";
  for (const code of chosen) {
    const token = document.createElement("button");
    token.type = "button";
    token.className = "chip";
    token.setAttribute("aria-pressed", "true");
    token.textContent = LANGUAGES[code] || code;
    const close = document.createElement("span");
    close.className = "x";
    close.textContent = "×";
    token.appendChild(close);
    token.setAttribute("aria-label", `Remove ${LANGUAGES[code] || code}`);
    token.title = "Remove";
    token.onclick = () => {
      save({ languageHints: chosen.filter((c) => c !== code) });
      renderLanguages();
    };
    host.appendChild(token);
  }

  picker.innerHTML = "";
  picker.add(new Option("Add language", ""));
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

const CLEANUP_NOTES = {
  light: "Light — removes filler words and stutters only. No restructuring.",
  medium: "Medium — also fixes punctuation and splits into paragraphs.",
  hard: "Hard — structures for reuse as AI instructions: bullets, sections, no fluff.",
  exp: "Exp — pastes raw instantly, races the models below in the background and logs outputs.",
};

function renderCleanupTier() {
  for (const chip of $("cleanupTier").children) {
    chip.setAttribute("aria-pressed", String(chip.dataset.value === config.cleanupTier));
    chip.onclick = () => {
      save({ cleanupTier: chip.dataset.value });
      renderCleanupTier();
    };
  }
  $("cleanupNote").textContent = CLEANUP_NOTES[config.cleanupTier] || "";
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

  let result;
  try { result = await window.app.verifyKey(key); }
  catch (err) { result = { ok: false, message: err.message }; }
  $("verify").disabled = false;
  if ($("apiKey").value.trim() !== key) {
    status.textContent = "Key changed. Verify the current key.";
    return;
  }

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
    setSelectValue("model", config.model);
  }
  renderUsage();
}

async function verifyOpenrouterKey() {
  const key = $("openrouterKey").value.trim();
  const status = $("openrouterStatus");
  if (!key) {
    status.className = "note bad";
    status.textContent = "Paste your OpenRouter API key first.";
    return;
  }
  $("verifyOpenrouter").disabled = true;
  status.className = "note";
  status.textContent = "Checking…";

  let result;
  try { result = await window.app.verifyOpenrouterKey(key); }
  catch (err) { result = { ok: false, message: err.message }; }
  $("verifyOpenrouter").disabled = false;
  if ($("openrouterKey").value.trim() !== key) {
    status.textContent = "Key changed. Verify the current key.";
    return;
  }

  if (!result.ok) {
    status.className = "note bad";
    status.textContent = `Key rejected — ${result.message}`;
    return;
  }
  status.className = "note ok";
  status.textContent = "Key works. Encrypted in your macOS Keychain.";
  renderOpenrouterUsage();
}

async function verifyModelField({ input, status: statusId, button }) {
  const model = $(input).value.trim();
  const key = $("openrouterKey").value.trim();
  const status = $(statusId);
  if (!model) {
    status.className = "note bad";
    status.textContent = "Enter a model ID first.";
    return;
  }
  $(button).disabled = true;
  status.className = "note";
  status.textContent = "Checking…";

  let result;
  try { result = await window.app.verifyCleanupModel({ key, model }); }
  catch (err) { result = { ok: false, message: err.message }; }
  $(button).disabled = false;
  if ($(input).value.trim() !== model) {
    status.textContent = "Model changed. Verify the current one.";
    return;
  }

  if (!result.ok) {
    status.className = "note bad";
    status.textContent = result.available?.length
      ? `Model not found — ${result.message} Similar: ${result.available.join(", ")}.`
      : `Model not found — ${result.message}`;
    return;
  }
  status.className = "note ok";
  status.textContent = result.contextLength
    ? `${result.name} exists — ${(result.contextLength / 1024).toFixed(0)}k context.`
    : `${result.name} exists.`;
}

const verifyCleanupModel = () => verifyModelField({ input: "cleanupModel", status: "modelStatus", button: "verifyModel" });
const verifyEmailModel = () => verifyModelField({ input: "emailModel", status: "emailModelStatus", button: "verifyEmailModel" });

async function verifyProviderField({ modelInput, input, status: statusId, button }) {
  const model = $(modelInput).value.trim();
  const provider = $(input).value.trim();
  const key = $("openrouterKey").value.trim();
  const status = $(statusId);
  $(button).disabled = true;
  status.className = "note";
  status.textContent = "Checking…";

  let result;
  try { result = await window.app.verifyCleanupProvider({ key, model, provider }); }
  catch (err) { result = { ok: false, message: err.message }; }
  $(button).disabled = false;
  if ($(input).value.trim() !== provider) {
    status.textContent = "Provider changed. Verify the current one.";
    return;
  }

  if (!result.ok) {
    status.className = "note bad";
    status.textContent = result.available?.length
      ? `${result.message} Available: ${result.available.join(", ")}.`
      : result.message;
    return;
  }
  status.className = "note ok";
  status.textContent = result.auto
    ? "Empty — OpenRouter routes automatically."
    : `${result.provider} serves this model${result.quantization ? ` (${result.quantization})` : ""}.`;
}

const verifyCleanupProvider = () => verifyProviderField({ modelInput: "cleanupModel", input: "cleanupProvider", status: "providerStatus", button: "verifyProvider" });
const verifyEmailProvider = () => verifyProviderField({ modelInput: "emailModel", input: "emailProvider", status: "emailProviderStatus", button: "verifyEmailProvider" });

/* ----------------------------------- boot ----------------------------------- */

(async () => {
  config = await window.app.getConfig();
  savedConfig = { ...config };

  $("apiKey").value = config.apiKey || "";
  $("openrouterKey").value = config.openrouterKey || "";
  $("cleanupModel").value = config.cleanupModel || "";
  $("cleanupProvider").value = config.cleanupProvider || "";
  $("experimentModels").value = config.experimentModels || "";
  $("cleanupEnabled").checked = config.cleanupEnabled;
  setSelectValue("model", config.model);
  setSelectValue("translateTo", config.translateTo || "");
  $("context").value = config.context || "";
  setSelectValue("silenceStopMs", String(config.silenceStopMs));
  $("autoPaste").checked = config.autoPaste;
  $("restoreClipboard").checked = config.restoreClipboard;
  $("saveHistory").checked = config.saveHistory;
  $("launchAtLogin").checked = config.launchAtLogin;
  $("emailEnabled").checked = config.emailEnabled;
  $("emailModel").value = config.emailModel || "";
  $("emailProvider").value = config.emailProvider || "";

  renderLanguages();
  renderPosition();
  renderCleanupTier();
  refreshPermissions();
  renderLocalStats();
  renderUsage();
  renderOpenrouterUsage();

  $("apiKey").oninput = debounce((e) => save({ apiKey: e.target.value.trim() }), 400);
  $("openrouterKey").oninput = debounce((e) => save({ openrouterKey: e.target.value.trim() }), 400);
  $("cleanupModel").oninput = debounce((e) => save({ cleanupModel: e.target.value.trim() }), 400);
  $("cleanupProvider").oninput = debounce((e) => save({ cleanupProvider: e.target.value.trim() }), 400);
  $("experimentModels").oninput = debounce((e) => save({ experimentModels: e.target.value }), 400);
  $("cleanupEnabled").onchange = (e) => save({ cleanupEnabled: e.target.checked });
  $("emailEnabled").onchange = (e) => save({ emailEnabled: e.target.checked });
  $("emailModel").oninput = debounce((e) => save({ emailModel: e.target.value.trim() }), 400);
  $("emailProvider").oninput = debounce((e) => save({ emailProvider: e.target.value.trim() }), 400);
  $("model").onchange = (e) => save({ model: e.target.value });
  $("translateTo").onchange = (e) => save({ translateTo: e.target.value });
  $("context").oninput = debounce((e) => save({ context: e.target.value }), 400);
  $("silenceStopMs").onchange = (e) => save({ silenceStopMs: Number(e.target.value) });
  $("autoPaste").onchange = (e) => save({ autoPaste: e.target.checked });
  $("restoreClipboard").onchange = (e) => save({ restoreClipboard: e.target.checked });
  $("saveHistory").onchange = (e) => save({ saveHistory: e.target.checked });
  $("launchAtLogin").onchange = (e) => save({ launchAtLogin: e.target.checked });

  $("verify").onclick = verifyKey;
  $("verifyOpenrouter").onclick = verifyOpenrouterKey;
  $("verifyModel").onclick = verifyCleanupModel;
  $("verifyProvider").onclick = verifyCleanupProvider;
  $("verifyEmailModel").onclick = verifyEmailModel;
  $("verifyEmailProvider").onclick = verifyEmailProvider;
  $("console").onclick = () => window.app.openConsole();
  $("openrouterConsole").onclick = () => window.app.openOpenrouterConsole();
  $("openExperiments").onclick = () => window.app.openExperiments();
  $("micBtn").onclick = async () => { await window.app.askMicrophone(); refreshPermissions(); };
  $("axBtn").onclick = () => window.app.askAccessibility();

  window.app.onHistoryChanged(renderLocalStats);
  window.addEventListener("focus", () => {
    refreshPermissions();
    renderLocalStats();
    if (Date.now() - usageUpdatedAt > 60000) { renderUsage(); renderOpenrouterUsage(); }
  });
  // Permissions can be granted in System Settings while this window sits open.
  setInterval(() => { if (!document.hidden) refreshPermissions(); }, 2000);
})();
