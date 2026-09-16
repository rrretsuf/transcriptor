const {
  app, BrowserWindow, Tray, Menu, globalShortcut, clipboard, ClipboardItem, ipcMain,
  safeStorage, screen, shell, nativeImage, systemPreferences, Notification, session, dialog,
} = require("electron");
const { execFile, spawn } = require("node:child_process");
const { randomUUID } = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const IS_MAC = process.platform === "darwin";

/* temporary startup trace: TRANSCRIBER_TRACE=1 enables; removed before release */
const TRACE_FILE = "/tmp/transcriber-startup-trace.log";
let traceFirst = false;
function trace(label) {
  if (process.env.TRANSCRIBER_TRACE !== "1") return;
  const line = `${label} ${Math.round(performance.now())}`;
  try {
    if (traceFirst) fs.appendFileSync(TRACE_FILE, line + "\n");
    else { traceFirst = true; fs.writeFileSync(TRACE_FILE, line + "\n"); }
  } catch { /* tracing must never break launch */ }
}
const CONFIG_PATH = path.join(app.getPath("userData"), "config.json");
const HISTORY_PATH = path.join(app.getPath("userData"), "history.json");
const HISTORY_LIMIT = 500;

const DEFAULTS = {
  apiKey: "",
  openrouterKey: "",
  cleanupEnabled: false,
  cleanupTier: "light",
  cleanupModel: "thinkingmachines/inkling-small",
  cleanupProvider: "baseten",
  experimentModels: "",
  emailEnabled: true,
  emailModel: "thinkingmachines/inkling-small",
  emailProvider: "baseten",
  model: "stt-rt-v5",
  languageHints: ["en"],
  context: "",
  translateTo: "",
  hotkey: "Command+Shift+Space",
  autoPaste: true,
  restoreClipboard: false,
  silenceStopMs: 0,
  launchAtLogin: false,
  position: "bottom",
  transcriptVisible: true,
  transcriptHeight: 180,
  saveHistory: true,
};

// A hotkey is either an Electron accelerator or "tap:<modifier>:<count>", which
// globalShortcut cannot express and a helper watching raw modifier flags can.
const KEYTAP = path.join(__dirname, "assets", "keytap").replace("app.asar", "app.asar.unpacked");
const TAP_MODIFIERS = [
  ["Command", 0x100000], ["Control", 0x040000], ["Option", 0x080000],
  ["Shift", 0x020000], ["Fn", 0x800000],
];
const MODIFIERS = 0x9e0000;
const TAP_GAP_MS = 400;

function parseTap(hotkey) {
  const [prefix, modifier, count] = String(hotkey).split(":");
  if (prefix !== "tap" || !TAP_MODIFIERS.some(([name]) => name === modifier)) return null;
  return Number(count) > 0 ? { modifier, count: Number(count) } : null;
}

// Collapsed, the surface is a bare capsule; open, it grows into a transcript panel.
const CAPSULE = 34;
const CAPSULE_LENGTH = 132;
const PANEL_WIDTH = 440;
const PANEL_MIN = 96;
const MARGIN = 20;

let config = { ...DEFAULTS };
let history = [];
let tray = null;
let surface = null;
let settingsWin = null;
let historyWin = null;
let state = "idle";
let sessionMode = "dictate";
let surfaceDisplay = null;
let contentHeight = PANEL_MIN;
let errorTimer = null;
let lastTranscript = "";
let encryptedKey = null;
let encryptedFor = "";
let encryptedOpenrouterKey = null;
let encryptedOpenrouterFor = "";
let keyUnlocked = false;
let openrouterUnlocked = false;
let configReadable = true;
let historyReadable = true;
let starting = false;
let clipboardVersion = 0;
let sessionId = 0;
let surfaceReady = null;
let surfaceLoaded = false;
let lastLayout = "";
let persistTimer = null;
let quitting = false;
let accessibilityPrompted = false;
let keytap = null;
let capturing = false;
let captureTimer = null;
let tapFlags = 0;
let tapArmed = null;
let tapName = "";
let tapCount = 0;
let tapDeadline = 0;
const trayIcons = new Map();

/* ---------------------------------- store ---------------------------------- */

function writeJSON(file, value) {
  const temporary = `${file}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(value, null, 2), { mode: 0o600 });
  fs.renameSync(temporary, file);
}

function loadConfig() {
  try {
    const raw = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
    if (!raw || Array.isArray(raw) || typeof raw !== "object"
      || Object.entries(DEFAULTS).some(([key, value]) => raw[key] !== undefined && typeof raw[key] !== typeof value)
      || (raw.languageHints !== undefined && (!Array.isArray(raw.languageHints) || raw.languageHints.some(v => typeof v !== "string")))) {
      throw new Error("Invalid settings");
    }
    const { apiKeyEnc, openrouterKeyEnc, ...rest } = raw;
    config = { ...DEFAULTS, ...Object.fromEntries(Object.entries(rest).filter(([key]) => key in DEFAULTS)) };
    encryptedKey = apiKeyEnc || null;
    encryptedOpenrouterKey = openrouterKeyEnc || null;
  } catch (err) {
    configReadable = err.code === "ENOENT";
    if (!configReadable) notify("Settings could not be read", "Your settings file has been kept intact. Restart after restoring it.");
  }
  encryptedFor = config.apiKey;
  encryptedOpenrouterFor = config.openrouterKey;
}

// Reading the keychain blocks on a system prompt, so it waits for something the
// user actually asked for rather than freezing launch before the hotkey exists.
function unlockApiKey() {
  if (!keyUnlocked) {
    keyUnlocked = true;
    if (encryptedKey) {
      try {
        config.apiKey = safeStorage.decryptString(Buffer.from(encryptedKey, "base64"));
      } catch {
        config.apiKey = "";
        notify("API key locked", "Allow Transcriber to use your keychain, or paste your key again in Settings.");
      }
      encryptedFor = config.apiKey;
    }
  }
  if (!openrouterUnlocked) {
    openrouterUnlocked = true;
    if (encryptedOpenrouterKey) {
      try {
        config.openrouterKey = safeStorage.decryptString(Buffer.from(encryptedOpenrouterKey, "base64"));
      } catch {
        config.openrouterKey = "";
        notify("OpenRouter key locked", "Allow Transcriber to use your keychain, or paste your key again in Settings.");
      }
      encryptedOpenrouterFor = config.openrouterKey;
    }
  }
}

function saveConfig(next = config) {
  if (!configReadable) throw new Error("Settings file could not be read. It has not been overwritten.");
  const { apiKey, openrouterKey, ...out } = next;
  if (encryptedKey && apiKey === encryptedFor) out.apiKeyEnc = encryptedKey;
  else if (apiKey) {
    if (!safeStorage.isEncryptionAvailable()) throw new Error("Keychain unavailable. Your API key was not saved.");
    out.apiKeyEnc = safeStorage.encryptString(apiKey).toString("base64");
  }
  if (encryptedOpenrouterKey && openrouterKey === encryptedOpenrouterFor) out.openrouterKeyEnc = encryptedOpenrouterKey;
  else if (openrouterKey) {
    if (!safeStorage.isEncryptionAvailable()) throw new Error("Keychain unavailable. Your OpenRouter key was not saved.");
    out.openrouterKeyEnc = safeStorage.encryptString(openrouterKey).toString("base64");
  }
  writeJSON(CONFIG_PATH, out);
  encryptedKey = out.apiKeyEnc || null;
  encryptedFor = apiKey;
  encryptedOpenrouterKey = out.openrouterKeyEnc || null;
  encryptedOpenrouterFor = openrouterKey;
}

function loadHistory() {
  try {
    const loaded = JSON.parse(fs.readFileSync(HISTORY_PATH, "utf8"));
    if (!Array.isArray(loaded) || loaded.some(e => !e || typeof e.text !== "string" || !Number.isFinite(e.at)
      || (e.words !== undefined && !Number.isFinite(e.words))
      || (e.durationMs !== undefined && !Number.isFinite(e.durationMs)))) {
      throw new Error("Invalid history");
    }
    history = loaded;
    lastTranscript = history[0]?.text || "";
  } catch (err) {
    historyReadable = err.code === "ENOENT";
    if (!historyReadable) notify("History could not be read", "Your history file has been kept intact. New dictation can still be copied.");
  }
}

function saveHistory(next) {
  if (!historyReadable) throw new Error("History file could not be read. It has not been overwritten.");
  writeJSON(HISTORY_PATH, next);
  history = next;
  historyWin?.webContents.send("history:changed");
  settingsWin?.webContents.send("history:changed");
}

function recordTranscript(text, durationMs) {
  lastTranscript = text;
  if (!config.saveHistory) return;
  const entry = {
    id: randomUUID(), text, at: Date.now(), durationMs,
    words: text.split(/\s+/).filter(Boolean).length,
  };
  try {
    saveHistory([entry, ...history].slice(0, HISTORY_LIMIT));
  } catch {
    notify("History could not be saved", "Your transcription is still available on the clipboard.");
  }
}

const STATS_PATH = path.join(app.getPath("userData"), "cleanup-stats.json");
const STATS_DEFAULT = { count: 0, promptTokens: 0, completionTokens: 0, costUsd: 0, emailCount: 0, emailCostUsd: 0 };
let cleanupStats = { ...STATS_DEFAULT };
let statsReadable = true;

function loadCleanupStats() {
  try {
    const loaded = JSON.parse(fs.readFileSync(STATS_PATH, "utf8"));
    if (!loaded || typeof loaded !== "object"
      || Object.entries(loaded).some(([key, value]) => !(key in STATS_DEFAULT) || !Number.isFinite(value))) {
      throw new Error("Invalid cleanup stats");
    }
    cleanupStats = { ...STATS_DEFAULT, ...loaded };
  } catch (err) {
    statsReadable = err.code === "ENOENT";
  }
}

function recordCleanup(usage, kind = "cleanup") {
  cleanupStats.count++;
  cleanupStats.promptTokens += usage?.prompt_tokens || 0;
  cleanupStats.completionTokens += usage?.completion_tokens || 0;
  cleanupStats.costUsd += Number(usage?.cost) || 0;
  if (kind === "email") {
    cleanupStats.emailCount++;
    cleanupStats.emailCostUsd += Number(usage?.cost) || 0;
  }
  if (!statsReadable) return;
  try {
    writeJSON(STATS_PATH, cleanupStats);
  } catch { /* stats are best-effort; the transcript itself is already safe */ }
}

/* --------------------------------- geometry -------------------------------- */

function surfaceBounds() {
  const display = surfaceDisplay || screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
  const { x, y, width, height } = display.workArea;
  const open = config.transcriptVisible;

  if (config.position === "bottom") {
    const panel = Math.min(Math.max(PANEL_MIN, config.transcriptHeight), contentHeight, height - 2 * MARGIN - CAPSULE);
    const w = open ? PANEL_WIDTH : CAPSULE_LENGTH;
    const h = open ? CAPSULE + panel : CAPSULE;
    return { x: Math.round(x + (width - w) / 2), y: y + height - MARGIN - h, width: w, height: h };
  }

  const panel = Math.min(Math.max(PANEL_MIN, config.transcriptHeight), contentHeight, height - 2 * MARGIN);
  const w = open ? CAPSULE + PANEL_WIDTH : CAPSULE;
  const h = open ? Math.max(CAPSULE_LENGTH, panel) : CAPSULE_LENGTH;
  return {
    x: config.position === "left" ? x + MARGIN : x + width - MARGIN - w,
    y: Math.round(y + (height - h) / 2),
    width: w,
    height: h,
  };
}

function layoutSurface() {
  const bounds = surfaceBounds();
  const previous = surface.getBounds();
  // Native animated resizing races the renderer layout and moves the click target.
  if (Object.keys(bounds).some(key => bounds[key] !== previous?.[key])) surface.setBounds(bounds);
  const layout = {
    position: config.position, open: config.transcriptVisible,
    height: bounds.height - (config.position === "bottom" ? CAPSULE : 0),
  };
  const signature = JSON.stringify(layout);
  if (signature !== lastLayout) {
    lastLayout = signature;
    surface.webContents.send("surface:layout", layout);
  }
}

/* ---------------------------------- windows -------------------------------- */

function createSurface() {
  surface = new BrowserWindow({
    ...surfaceBounds(),
    show: false,
    frame: false,
    transparent: true,
    vibrancy: "hud",
    visualEffectState: "active",
    roundedCorners: true,
    hasShadow: true,
    resizable: false,
    movable: false,
    focusable: false,
    skipTaskbar: true,
    alwaysOnTop: true,
    fullscreenable: false,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      backgroundThrottling: false,
    },
  });
  surface.setAlwaysOnTop(true, "screen-saver");
  surface.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  surfaceReady = surface.loadFile(path.join(__dirname, "renderer", "pill.html"));
  surface.webContents.on("did-finish-load", () => {
    surfaceLoaded = true;
    trace("pill-loaded");
    if (process.env.TRANSCRIBER_TRACE === "1") {
      surface.webContents.executeJavaScript("window.__trace = true").catch(() => {});
      surface.webContents.on("console-message", (_e, _l, msg) => {
        if (msg.startsWith("[trace]")) try { fs.appendFileSync(TRACE_FILE, msg.replace("[trace]", "renderer") + "\n"); } catch { /* ignore */ }
      });
    }
  });

  // Paint once off-screen so the first hotkey press reveals a warm, composited window.
  surface.once("ready-to-show", () => {
    trace("ready-to-show");
    surface.setPosition(-3000, -3000);
    surface.showInactive();
    setTimeout(() => { surface.hide(); trace("warm-paint-done"); }, 200);
  });

  // A dead renderer would otherwise wedge the hotkey until the app is restarted.
  surface.webContents.on("render-process-gone", () => {
    surfaceLoaded = false;
    globalShortcut.unregister("Escape");
    setState("idle");
    surface.destroy();
    createSurface();
  });
}

function panelWindow(file, { width, height, title }) {
  const win = new BrowserWindow({
    width,
    height,
    minWidth: width - 80,
    minHeight: 520,
    title,
    titleBarStyle: IS_MAC ? "hiddenInset" : "default",
    vibrancy: IS_MAC ? "under-window" : undefined,
    visualEffectState: "active",
    backgroundColor: "#00000000",
    show: false,
    webPreferences: { preload: path.join(__dirname, "preload.js") },
  });
  win.loadFile(path.join(__dirname, "renderer", file));
  win.once("ready-to-show", () => reveal(win));
  // Keeping the window alive makes every reopen instant instead of a fresh page load.
  win.on("close", (event) => {
    if (quitting) return;
    event.preventDefault();
    win.hide();
  });
  return win;
}

// Dock-hidden apps order a new window behind the active app unless they activate first.
function reveal(win) {
  if (IS_MAC) app.focus({ steal: true });
  win.show();
  win.focus();
}

function openSettings() {
  if (settingsWin && !settingsWin.isDestroyed()) return reveal(settingsWin);
  settingsWin = panelWindow("settings.html", { width: 580, height: 720, title: "Settings" });
  settingsWin.on("closed", () => { settingsWin = null; });
  settingsWin.on("hide", () => {
    capturing = false;
    applyKeytap();
  });
}

function openHistory() {
  if (historyWin && !historyWin.isDestroyed()) return reveal(historyWin);
  historyWin = panelWindow("history.html", { width: 620, height: 720, title: "Transcriptions" });
  historyWin.on("closed", () => { historyWin = null; });
}

/* ------------------------------ cleanup (OpenRouter) ------------------------------ */

const CLEANUP_TIMEOUT_MS = 8000;
const CLEANUP_TIERS = ["light", "medium", "hard"];

const CLEANUP_BASE = `You turn a raw speech-to-text transcript into clean written text. Return ONLY the cleaned text — no preamble, no quotes, no commentary.
- Keep the original language — never translate. Add no facts and summarize nothing away.
- Fix transcription errors that are obvious from context.
- If the speaker dictates a question or a chat message, output only the cleaned text — never answer or respond to it.
- Self-corrections replace what came before — "actually", "wait", "I mean", "scratch that", "oziroma", "pravzaprav", "pardon", "mislim": keep only the corrected version.
- When the speaker says the same thing twice, keep only the single best version.`;

const CLEANUP_EXAMPLE = `Example:
Input: "torej eee jutri se dobiva ob desetih a ne ne pardon ob enajstih pa prinesi še tisti dokument"
Output: "Jutri se dobiva ob enajstih. Prinesi še tisti dokument."`;

const CLEANUP_PROMPTS = {
  light: `${CLEANUP_BASE}
- Remove filler words and hesitations (um, eee, pač, ful, a veš, ne vem, mmm), stutters, repeated words and half-sentences.
- Fix only clearly missing punctuation. Do not restructure: keep the original word order, sentences and line breaks.`,
  medium: `${CLEANUP_BASE}
- Remove filler words and hesitations, stutters and repetitions.
- Merge sentence fragments caused by pauses into fluent sentences when they form one idea.
- Fix punctuation and capitalization; convert spoken punctuation ("comma", "period", "question mark", "new line", "new paragraph") to symbols and breaks.
- Split the text into short paragraphs. Keep every fact and the original order.

${CLEANUP_EXAMPLE}`,
  hard: `${CLEANUP_BASE}
- Remove filler words, stutters, repetitions and redundant context.
- Fix punctuation; convert spoken punctuation to symbols and breaks.
- Structure the text for reuse as AI instructions: short paragraphs, "- " bullets when items are enumerated, blank lines between sections. Detect enumerations and turn them into bullets.
- Keep every fact, add nothing.

${CLEANUP_EXAMPLE}`,
};

// Learned from 100 of Filip Kustec's sent emails (Slovenian ~80%, English ~20%).
const EMAIL_SYSTEM_PROMPT = `You turn a dictated, messy transcript into an email written exactly like Filip Kustec.
Return ONLY the email: first line "zadeva: <short subject>", then a blank line, then the body. No commentary, no quotes.
Write in the same language as the transcript (usually Slovenian; English only if the transcript is English).
Remove filler words, hesitations, stutters and repetitions first — when the speaker says the same thing twice, keep only the single best version.

LOWERCASE ALWAYS: the ENTIRE output is lowercase — subject, greeting, body, closing, name. No capital letters
anywhere, not even at sentence starts. Only URLs keep their original form. Domain terms stay lowercase too.

SLOVENIAN RULES:
- Greeting is always "živjo," (lowercase + comma). No "Pozdravljeni", "Spoštovani", "Dragi" or "Hej" — never.
- Tikanje (ti-forms), never vikanje, unless the transcript clearly addresses formal support.
- Very short, direct, first-person sentences. Softeners, not imperatives: "lahko", "bi prosil", "če lahko", "prosim".
- Closing is exactly two lines with no blank line between: "lep pozdrav," then "filip" on the next line. Never "lp".
- Never open with "upam, da ste dobro" or any well-wish preamble. Go straight to the point.
- Deadlines and next steps inline, conversational, as a question: "ti pošljem danes proti koncu dneva. je tako uredu?"
- Thanks are short: "hvala", "najlepša hvala." Apologies own the mistake with a fix: "sori …", "to je moja napaka …".

ENGLISH RULES (still all lowercase, including "hello," and the closing):
- Greeting is "hello,". Closing is exactly two lines with no blank line between: "best regards," then "filip".
- Complete polite sentences, first person. Thanks can be warm: "thank you so much for …".
- Never open with "hope you are well".

BOTH LANGUAGES:
- 1–3 short paragraphs by default. Plain "-" bullets only for real lists. No bold, no headings, no markdown, no tables.
- Links pasted bare, never hyperlinked text. No signature block, no phone, no title — first name only, lowercase.
- No "!!!", no "ASAP". Single "!" at most, rarely.
- Keep every fact from the transcript. Add nothing.`;

let polishAbort = null;

function cleanupWanted(text) {
  return config.cleanupEnabled
    && CLEANUP_TIERS.includes(config.cleanupTier)
    && Boolean(config.openrouterKey)
    && Boolean((config.cleanupModel || "").trim())
    && Boolean(text && text.trim().split(/\s+/).length > 2);
}

/* ------------------------------ cleanup experiment ------------------------------ */

// "exp" tier: the raw transcript pastes instantly while every configured model
// cleans it in the background; outputs land in a per-dictation folder so the
// best model can be picked from a day of real usage.
const EXPERIMENT_DIR = path.join(app.getPath("documents"), "Transcriber Experiments");

// One model per line, optional "@ provider" suffix, up to 6.
function experimentModels() {
  return (config.experimentModels || "")
    .split("\n")
    .map(line => line.trim())
    .filter(Boolean)
    .slice(0, 6)
    .map(line => {
      const [model, provider] = line.split("@").map(part => part.trim());
      return { model, provider: provider || "" };
    })
    .filter(entry => entry.model);
}

function experimentWanted(text) {
  return config.cleanupEnabled
    && config.cleanupTier === "exp"
    && Boolean(config.openrouterKey)
    && experimentModels().length > 0
    && Boolean(text && text.trim().split(/\s+/).length > 2);
}

async function runExperiment(text) {
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const dir = path.join(EXPERIMENT_DIR, stamp);
  try {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, "raw.txt"), text + "\n");
  } catch { return; }
  const system = withUserContext(CLEANUP_PROMPTS.medium);
  const outputs = await Promise.all(experimentModels().map(async ({ model, provider }) => {
    const started = Date.now();
    const makeBody = (t) => openrouterBody({ model, providerRaw: provider, system, text: t });
    const result = await openrouterChat(makeBody, text, null, "exp");
    if (result.ok) recordCleanup(result.usage);
    const cost = Number(result.usage?.cost);
    return `## ${model}${provider ? ` @ ${provider}` : ""}\n`
      + `latency: ${Date.now() - started} ms\n`
      + `cost: ${result.ok && Number.isFinite(cost) ? `$${cost.toFixed(5)}` : "—"}\n\n`
      + (result.ok ? result.text : `ERROR: ${result.reason}`) + "\n";
  }));
  try { fs.writeFileSync(path.join(dir, "outputs.md"), outputs.join("\n---\n\n")); } catch { /* best effort */ }
}

const KNOWN_QUANTIZATIONS = new Set(["fp4", "fp6", "fp8", "fp16", "fp32", "bf16", "int4", "int8", "int16", "unknown"]);

// "baseten/fp8" → { name: "baseten", quantization: "fp8" }. A multi-part endpoint
// tag like "google-vertex/global/priority" stays whole — only a trailing segment
// that is a real quantization is split off. "" → null (auto routing).
function parseCleanupProvider(raw) {
  const trimmed = (raw || "").trim();
  if (!trimmed) return null;
  const lastSlash = trimmed.lastIndexOf("/");
  const tail = lastSlash > 0 ? trimmed.slice(lastSlash + 1) : "";
  if (KNOWN_QUANTIZATIONS.has(tail.toLowerCase())) {
    const name = trimmed.slice(0, lastSlash).trim();
    if (name) return { name, quantization: tail };
  }
  return { name: trimmed, quantization: null };
}

const LANG_NAMES = {
  sl: "Slovenian", en: "English", de: "German", it: "Italian", hr: "Croatian",
  sr: "Serbian", bs: "Bosnian", fr: "French", es: "Spanish", pt: "Portuguese",
  nl: "Dutch", pl: "Polish", cs: "Czech", sk: "Slovak", hu: "Hungarian",
  ro: "Romanian",
};

// The cleanup/email model inherits the user's Soniox context: speech language
// hints plus the vocabulary terms, so it knows the language and the jargon.
function withUserContext(system, preserveTermCase = true) {
  const languages = (config.languageHints || []).map(code => LANG_NAMES[code] || code).filter(Boolean);
  const terms = (config.context || "").split(/[,\n]+/).map(term => term.trim()).filter(Boolean);
  if (languages.length) system += ` The transcript is in: ${languages.join(", ")}. Reply in the same language.`;
  if (terms.length) system += preserveTermCase
    ? ` Preserve these domain terms exactly as written: ${terms.join(", ")}.`
    : ` Preserve the spelling of these domain terms, but follow the lowercase rule above: ${terms.join(", ")}.`;
  return system;
}

function openrouterBody({ model, providerRaw, system, text }) {
  const words = text.trim().split(/\s+/).length;
  const provider = parseCleanupProvider(providerRaw);
  const body = {
    model,
    max_completion_tokens: Math.min(4000, Math.max(1200, Math.round(words * 2) + 400)),
    stream: false,
    usage: { include: true },
    reasoning: { effort: "none", exclude: true },
    messages: [
      { role: "system", content: system },
      { role: "user", content: text },
    ],
  };
  if (provider) {
    body.provider = { order: [provider.name], allow_fallbacks: true };
    if (provider.quantization) body.provider.quantizations = [provider.quantization];
  }
  return body;
}

async function openrouterChat(makeBody, text, signal, mode) {
  // Prefer no reasoning for this transformation. If a model requires reasoning,
  // retry with low effort, then its provider default. Empty length-limited replies
  // also retry with more room because reasoning and visible text share one budget.
  let compatibility = 0;
  const startedAt = Date.now();
  let outcome = "retry";
  for (let attempt = 0; attempt < 3; attempt++) {
    const body = makeBody(text);
    if (compatibility === 1) body.reasoning = { effort: "low", exclude: true };
    if (compatibility >= 2) delete body.reasoning;
    if (attempt > 0) body.max_completion_tokens = Math.min(8000, body.max_completion_tokens * 2);
    try {
      const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${config.openrouterKey}`,
          "Content-Type": "application/json",
          "HTTP-Referer": "https://transcriber.local",
          "X-Title": "Transcriber",
        },
        body: JSON.stringify(body),
        signal: signal ?? AbortSignal.timeout(CLEANUP_TIMEOUT_MS),
      });
      if (res.status === 400 && attempt < 2) {
        compatibility++;
        continue;
      }
      if (res.status === 429 && attempt < 2) {
        await new Promise(r => setTimeout(r, 800));
        continue;
      }
      if (!res.ok) { outcome = `HTTP ${res.status}`; break; }
      const data = await res.json().catch(() => null);
      const choice = data?.choices?.[0];
      const rawContent = choice?.message?.content;
      const content = (typeof rawContent === "string"
        ? rawContent
        : Array.isArray(rawContent)
          ? rawContent.map(part => typeof part === "string" ? part : part?.text || "").join("")
          : "").trim();
      if (!content) {
        const finish = choice?.finish_reason || choice?.native_finish_reason || "blank";
        const used = data?.usage?.completion_tokens;
        const reasoning = data?.usage?.completion_tokens_details?.reasoning_tokens;
        outcome = `empty/${finish}${Number.isFinite(used) ? `/tokens:${used}` : ""}`
          + `${Number.isFinite(reasoning) ? `/reasoning:${reasoning}` : ""}`;
        if (attempt < 2) { compatibility++; continue; }
        break;
      }
      const result = { ok: true, text: content, usage: data?.usage || null };
      traceAi(makeBody, mode, true, Date.now() - startedAt);
      return result;
    } catch (err) {
      if (err?.name === "AbortError") { outcome = "aborted"; break; }
      if (attempt < 2) {
        await new Promise(r => setTimeout(r, 800));
        continue;
      }
      outcome = err?.message || "network";
    }
  }
  traceAi(makeBody, mode, false, Date.now() - startedAt, outcome);
  return { ok: false, reason: outcome };
}

// One-line debug trail for every AI call: tail /tmp/transcriber-ai.log to see
// what the last dictation did (mode, model, latency, outcome).
function traceAi(makeBody, mode, ok, ms, reason = "") {
  try {
    const probe = makeBody("");
    const line = `${new Date().toISOString()} mode=${mode || "?"} model=${probe.model} `
      + `provider=${probe.provider?.order?.[0] || "auto"} ms=${ms} ${ok ? "ok" : `fail:${reason}`}\n`;
    fs.appendFileSync("/tmp/transcriber-ai.log", line);
  } catch { /* logging must never break dictation */ }
}

function cleanupRequest(text) {
  return openrouterBody({
    model: (config.cleanupModel || "").trim() || DEFAULTS.cleanupModel,
    providerRaw: config.cleanupProvider,
    system: withUserContext(CLEANUP_PROMPTS[config.cleanupTier] || CLEANUP_PROMPTS.light),
    text,
  });
}

function emailRequest(text) {
  return openrouterBody({
    model: (config.emailModel || "").trim() || DEFAULTS.emailModel,
    providerRaw: config.emailProvider,
    system: withUserContext(EMAIL_SYSTEM_PROMPT, false),
    text,
  });
}

async function cleanupTranscript(text, signal) {
  return openrouterChat(cleanupRequest, text, signal, "cleanup");
}

function emailWanted(text) {
  return config.emailEnabled
    && Boolean(config.openrouterKey)
    && Boolean((config.emailModel || "").trim())
    && Boolean(text && text.trim().split(/\s+/).length > 2);
}

async function emailTranscript(text, signal) {
  const result = await openrouterChat(emailRequest, text, signal, "email");
  if (!result.ok) return result;
  // The user's email style requires lowercase output. Enforce it after generation
  // instead of relying on every interchangeable model to follow the prompt.
  const parts = result.text.split(/(\b(?:https?:\/\/|www\.)[^\s]+)/gi);
  result.text = parts.map(part => /^(?:https?:\/\/|www\.)/i.test(part) ? part : part.toLocaleLowerCase("sl-SI")).join("");
  return result;
}

/* ----------------------------------- tray ---------------------------------- */

function trayIcon(active) {
  if (trayIcons.has(active)) return trayIcons.get(active);
  const img = nativeImage.createFromPath(
    path.join(__dirname, "assets", active ? "trayActiveTemplate.png" : "trayTemplate.png")
  );
  img.setTemplateImage(true);
  trayIcons.set(active, img);
  return img;
}

function buildTrayMenu() {
  if (!tray) return;
  const label =
    state === "recording" ? (sessionMode === "email" ? "Stop email" : "Stop dictation")
    : state === "finishing" ? "Finishing…"
    : state === "polishing" ? "Polishing…"
    : "Start dictation";
  tray.setContextMenu(Menu.buildFromTemplate([
    { label, accelerator: config.hotkey, click: () => toggle(), enabled: state !== "finishing" && state !== "polishing" },
    {
      label: "Copy last transcription",
      enabled: Boolean(lastTranscript),
      click: () => writeClipboard(lastTranscript).catch(() => notify("Copy failed", "Try copying from Transcriptions again.")),
    },
    { type: "separator" },
    { label: "All transcriptions…", click: openHistory },
    { label: "Settings…", accelerator: "Command+,", click: openSettings },
    { type: "separator" },
    { label: "Quit", accelerator: "Command+Q", click: () => app.quit() },
  ]));
}

function setState(next) {
  state = next;
  if (next === "idle") sessionMode = "dictate";
  tray?.setImage(trayIcon(next !== "idle"));
  setImmediate(buildTrayMenu);
}

/* --------------------------------- dictation -------------------------------- */

function notify(title, body) {
  if (Notification.isSupported()) new Notification({ title, body, silent: true }).show();
}

const KEY_SYMBOLS = { Command: "⌘", Control: "⌃", Alt: "⌥", Option: "⌥", Shift: "⇧" };
function hotkeyLabel() {
  const tap = parseTap(config.hotkey);
  if (tap) return Array(tap.count).fill(KEY_SYMBOLS[tap.modifier] ?? tap.modifier).join(" ");
  return config.hotkey.split("+").map((part) => KEY_SYMBOLS[part] ?? part).join("");
}

function sessionConfig() {
  return {
    id: sessionId,
    hotkeyLabel: hotkeyLabel(),
    apiKey: config.apiKey,
    model: config.model,
    languageHints: config.languageHints,
    context: config.context,
    translateTo: config.translateTo,
    silenceStopMs: config.silenceStopMs,
    position: config.position,
    open: config.transcriptVisible,
    height: config.transcriptHeight,
  };
}

async function toggle() {
  trace("toggle:invoked");
  if (state === "recording") return stop();
  if (state !== "idle" || starting) return;
  sessionMode = "dictate";
  return beginSession();
}

async function startEmail() {
  if (state === "recording") return stop();
  if (state !== "idle" || starting) return;
  if (!config.emailEnabled) {
    notify("Email dictation is off", "Turn it on in Settings to dictate emails with ⌘⇧E.");
    return;
  }
  sessionMode = "email";
  return beginSession();
}

async function beginSession() {
  trace("toggle:unlocking");
  unlockApiKey();
  trace("toggle:unlocked");
  if (!config.apiKey) {
    notify("Transcriber", "Add your Soniox API key in Settings first.");
    openSettings();
    return;
  }
  starting = true;
  try {
    trace("toggle:before-await");
    // Awaiting an already-resolved Electron promise still parks the hotkey path in the
    // event loop, where macOS can park the napped app for seconds; press time is long
    // past load, so only a genuinely-unloaded surface is allowed to wait.
    if (!surfaceLoaded) await surfaceReady;
    trace("toggle:surface-ready");
    if (IS_MAC && systemPreferences.getMediaAccessStatus("microphone") !== "granted") {
      if (!(await systemPreferences.askForMediaAccess("microphone"))) {
        notify("Microphone blocked", "Allow microphone access to dictate.");
        openSettings();
        return;
      }
    }
    clearTimeout(errorTimer);
    trace("toggle:mic-checked");
    surfaceDisplay = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
    contentHeight = PANEL_MIN;
    sessionId++;
    lastLayout = "";
    setState("recording");
    trace("toggle:state-set");
    layoutSurface();
    trace("toggle:layout-done");
    surface.webContents.send("session:start", sessionConfig());
    trace("toggle:start-sent");
    surface.showInactive();
    trace("toggle:shown");
    globalShortcut.register("Escape", cancel);
  } catch (err) { notify("Could not start dictation", err.message); }
  finally { starting = false; }
}

function stop() {
  if (state !== "recording") return;
  setState("finishing");
  surface.webContents.send("session:stop");
}

function cancel() {
  if (state === "idle") return;
  polishAbort?.abort();
  polishAbort = null;
  globalShortcut.unregister("Escape");
  surface.webContents.send("session:cancel");
  surface.hide();
  setState("idle");
}

async function writeClipboard(text) {
  const version = ++clipboardVersion;
  await clipboard.writeText(text);
  return version;
}

async function snapshotClipboard() {
  const items = await clipboard.read();
  return Promise.all(items.map(async item => new ClipboardItem(Object.fromEntries(
    await Promise.all(item.types.map(async type => [type, await item.getType(type)]))
  ))));
}

const clipboardFormats = items => JSON.stringify(items.map(item => [...item.types].sort()));

async function pasteAtCursor(text) {
  const previous = config.restoreClipboard && config.autoPaste ? await snapshotClipboard() : null;
  const version = await writeClipboard(text);
  if (!config.autoPaste || settingsWin?.isFocused() || historyWin?.isFocused()) return;
  if (IS_MAC && !systemPreferences.isTrustedAccessibilityClient(false)) {
    if (accessibilityPrompted) return;
    accessibilityPrompted = true;
    notify("Transcriber cannot paste yet", "Your transcription is on the clipboard. Turn on Accessibility to paste automatically.");
    openSettings();
    return;
  }
  const writtenFormats = previous ? clipboardFormats(await clipboard.read()) : null;
  if (version !== clipboardVersion) return;
  execFile(KEYTAP, ["--paste"], (err) => {
    if (err) {
      notify("Paste failed", "Your transcription is on the clipboard.");
      return;
    }
    if (previous !== null) setTimeout(async () => {
      try {
        const current = await clipboard.read();
        if (version !== clipboardVersion || await clipboard.readText() !== text) return;
        if (clipboardFormats(current) !== writtenFormats) return;
        // Restore all saved formats, but never replace a newer copy operation.
        if (version === clipboardVersion) await clipboard.write(previous);
      } catch { /* Keep the transcription if the clipboard cannot be restored. */ }
    }, 800);
  });
}

const EMAIL_HOTKEY = "Command+Shift+E";

function registerHotkey() {
  globalShortcut.unregisterAll();
  if (state !== "idle") globalShortcut.register("Escape", cancel);
  applyKeytap();
  registerEmailHotkey();
  if (parseTap(config.hotkey)) return;
  if (!globalShortcut.register(config.hotkey, () => { trace("hotkey:fired"); toggle(); })) {
    notify("Hotkey unavailable", `${config.hotkey} is already taken by another app.`);
  }
}

function registerEmailHotkey() {
  if (!config.emailEnabled || config.hotkey === EMAIL_HOTKEY) return;
  if (!globalShortcut.register(EMAIL_HOTKEY, () => { trace("email-hotkey:fired"); startEmail(); })) {
    notify("Email hotkey unavailable", `${EMAIL_HOTKEY} is already taken by another app.`);
  }
}

// Disk and keychain writes on every click would stutter the surface; batch them instead.
function persistConfig() {
  clearTimeout(persistTimer);
  persistTimer = setTimeout(flushConfig, 500);
}

function flushConfig() {
  clearTimeout(persistTimer);
  persistTimer = null;
  try { saveConfig(); } catch (err) { notify("Settings not saved", err.message); }
}

// A tap only counts when its modifier is pressed and released completely alone.
function readTap(line) {
  if (line === "key") return void (tapArmed = null);
  if (!line.startsWith("flags ")) return;

  const flags = Number(line.slice(6));
  const before = tapFlags;
  tapFlags = flags;
  const held = flags & MODIFIERS;

  const pressed = TAP_MODIFIERS.find(([, bit]) => (flags & bit) && !(before & bit));
  if (pressed) return void (tapArmed = held === pressed[1] ? pressed[0] : null);
  if (held) return void (tapArmed = null);

  const released = TAP_MODIFIERS.find(([, bit]) => before & bit);
  if (!released || released[0] !== tapArmed) return void (tapArmed = null);
  tapArmed = null;

  const now = Date.now();
  if (tapName !== released[0] || now > tapDeadline) tapCount = 0;
  tapName = released[0];
  tapCount++;
  tapDeadline = now + TAP_GAP_MS;
  countTap();
}

function countTap() {
  if (capturing) {
    clearTimeout(captureTimer);
    const taken = { modifier: tapName, count: tapCount };
    captureTimer = setTimeout(() => settingsWin?.webContents.send("hotkey:tap", taken), TAP_GAP_MS);
    return;
  }
  const wanted = parseTap(config.hotkey);
  if (!wanted || wanted.modifier !== tapName || tapCount < wanted.count) return;
  tapCount = 0;
  toggle();
}

function applyKeytap() {
  if (!capturing && !parseTap(config.hotkey)) {
    keytap?.kill();
    keytap = null;
    return;
  }
  if (keytap) return;

  keytap = spawn(KEYTAP, { stdio: ["ignore", "pipe", "ignore"] });
  keytap.on("error", () => notify("Hotkey watcher unavailable", "Fn and double-tap hotkeys are not available."));
  keytap.on("exit", () => { keytap = null; });

  let pending = "";
  keytap.stdout.on("data", (chunk) => {
    const lines = (pending + chunk).split("\n");
    pending = lines.pop();
    for (const line of lines) {
      if (line !== "denied") readTap(line);
      else settingsWin?.webContents.send("hotkey:tap", { denied: true });
    }
  });
}

function applyLoginItem() {
  try {
    if (app.getLoginItemSettings().openAtLogin === config.launchAtLogin) return;
    app.setLoginItemSettings({ openAtLogin: config.launchAtLogin });
  } catch {
    /* unsigned dev builds cannot register a login item */
  }
}

/* ------------------------------------ ipc ----------------------------------- */

ipcMain.on("session:result", async (_e, { id, text, durationMs }) => {
  if (id !== sessionId || state === "idle") return;
  globalShortcut.unregister("Escape");
  const clean = (text || "").trim();
  if (!clean) {
    surface.hide();
    setState("idle");
    return;
  }
  const mode = sessionMode;
  const wanted = mode === "email" ? emailWanted(clean) : cleanupWanted(clean);
  if (!wanted) {
    surface.hide();
    setState("idle");
    recordTranscript(clean, durationMs);
    buildTrayMenu();
    if (mode !== "email" && experimentWanted(clean)) runExperiment(clean).catch(() => {});
    try { await pasteAtCursor(clean); }
    catch { notify("Copy failed", "Your transcription is available in Transcriptions if history is enabled."); }
    return;
  }
  // AI path: the capsule stays visible in a loading state until the
  // polished text (or the original, on failure) is pasted.
  const polishingId = id;
  setState("polishing");
  surface.webContents.send("session:polishing");
  surface.showInactive();
  polishAbort = new AbortController();
  const timeout = setTimeout(() => polishAbort.abort(), CLEANUP_TIMEOUT_MS + 2000);
  let polished = null;
  try {
    const result = mode === "email"
      ? await emailTranscript(clean, polishAbort.signal)
      : await cleanupTranscript(clean, polishAbort.signal);
    if (polishingId !== sessionId) return;
    if (result.ok && result.text) {
      polished = result.text;
      recordCleanup(result.usage, mode);
    }
    else if (result.reason === "HTTP 401" || result.reason === "HTTP 402" || result.reason === "HTTP 403") {
      notify(mode === "email" ? "Email skipped" : "Cleanup skipped",
        "Your OpenRouter key was rejected. The original transcription was pasted.");
    }
    else if (mode === "email") {
      notify("Email not structured", `The email model failed (${result.reason}). The original transcription was pasted.`);
    }
  } finally {
    clearTimeout(timeout);
    polishAbort = null;
  }
  if (polishingId !== sessionId || state !== "polishing") return;
  surface.hide();
  setState("idle");
  const final = polished || clean;
  recordTranscript(final, durationMs);
  buildTrayMenu();
  try { await pasteAtCursor(final); }
  catch { notify("Copy failed", "Your transcription is available in Transcriptions if history is enabled."); }
});

ipcMain.on("session:error", async (_e, { id, message, text, durationMs }) => {
  if (id !== sessionId || state === "idle") return;
  if (text) {
    recordTranscript(text, durationMs);
  }
  globalShortcut.unregister("Escape");
  setState("idle");
  const { x, y, width, height } = surface.getBounds();
  const area = (surfaceDisplay || screen.getDisplayNearestPoint(screen.getCursorScreenPoint())).workArea;
  const errorX = Math.max(area.x + MARGIN, Math.min(x + (width - 260) / 2, area.x + area.width - MARGIN - 260));
  const errorY = config.position === "bottom" ? y + height - CAPSULE : y + (height - CAPSULE) / 2;
  surface.setBounds({ x: Math.round(errorX), y: Math.round(errorY), width: 260, height: CAPSULE });
  clearTimeout(errorTimer);
  errorTimer = setTimeout(() => { if (state === "idle") surface.hide(); }, 2400);
  surface.showInactive();
  if (text) { try { await writeClipboard(text); } catch { text = ""; } }
  notify("Transcription failed", text ? `${message}. Partial transcription copied to the clipboard.` : message);
});

ipcMain.on("session:autostop", () => stop());

ipcMain.on("surface:toggle", () => {
  if (state === "idle") return;
  config.transcriptVisible = !config.transcriptVisible;
  layoutSurface();
  persistConfig();
});

ipcMain.on("surface:resize", (_e, height) => {
  if (!Number.isFinite(height)) return;
  const workArea = (surfaceDisplay || screen.getDisplayNearestPoint(screen.getCursorScreenPoint())).workArea;
  const maxHeight = Math.min(contentHeight, workArea.height - 2 * MARGIN - (config.position === "bottom" ? CAPSULE : 0));
  config.transcriptHeight = Math.min(maxHeight, Math.max(PANEL_MIN, Math.round(height)));
  layoutSurface();
});

ipcMain.on("surface:resized", () => persistConfig());

ipcMain.on("surface:content", (_e, height) => {
  if (!Number.isFinite(height) || !config.transcriptVisible) return;
  const next = Math.max(PANEL_MIN, Math.ceil(height));
  if (next === contentHeight) return;
  contentHeight = next;
  if (state !== "idle") layoutSurface();
});

ipcMain.handle("config:get", () => {
  unlockApiKey();
  return { ...config, hasKey: Boolean(config.apiKey) };
});

ipcMain.handle("config:set", (_e, patch) => {
  for (const [key, value] of Object.entries(patch)) {
    if (!Object.hasOwn(DEFAULTS, key) || typeof value !== typeof DEFAULTS[key]
      || (typeof value === "number" && !Number.isFinite(value))
      || (key === "languageHints" && (!Array.isArray(value) || value.some(v => typeof v !== "string")))) {
      throw new Error("Invalid setting");
    }
  }
  if (patch.position !== undefined && !["bottom", "left", "right"].includes(patch.position)) throw new Error("Invalid position");
  if (patch.cleanupTier !== undefined && ![...CLEANUP_TIERS, "exp"].includes(patch.cleanupTier)) throw new Error("Invalid cleanup tier");
  const hotkeyChanged = patch.hotkey !== undefined && patch.hotkey !== config.hotkey;
  if (hotkeyChanged && !parseTap(patch.hotkey)) {
    globalShortcut.unregisterAll();
    let usable = false;
    try { usable = Boolean(patch.hotkey) && globalShortcut.register(patch.hotkey, toggle); } catch { usable = false; }
    globalShortcut.unregisterAll();
    if (!usable) {
      registerHotkey();
      throw new Error("Hotkey unavailable. Your previous hotkey is still active.");
    }
  }
  const next = { ...config, ...patch };
  const oldEncryptedKey = encryptedKey;
  const oldEncryptedOpenrouterKey = encryptedOpenrouterKey;
  if (patch.apiKey === "") encryptedKey = null;
  if (patch.openrouterKey === "") encryptedOpenrouterKey = null;
  try { saveConfig(next); }
  catch (err) {
    encryptedKey = oldEncryptedKey;
    encryptedOpenrouterKey = oldEncryptedOpenrouterKey;
    registerHotkey();
    throw err;
  }
  config = next;
  if (patch.position) layoutSurface();
  if (patch.launchAtLogin !== undefined) applyLoginItem();
  if (hotkeyChanged || patch.emailEnabled !== undefined) { registerHotkey(); buildTrayMenu(); }
  return { ...config, hasKey: Boolean(config.apiKey) };
});

ipcMain.handle("perm:status", () => ({
  microphone: IS_MAC ? systemPreferences.getMediaAccessStatus("microphone") : "granted",
  accessibility: IS_MAC ? systemPreferences.isTrustedAccessibilityClient(false) : true,
}));

ipcMain.handle("perm:microphone", () => systemPreferences.askForMediaAccess("microphone"));

ipcMain.handle("perm:accessibility", () => {
  systemPreferences.isTrustedAccessibilityClient(true);
  shell.openExternal("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility");
  return true;
});

ipcMain.handle("history:list", () => history);

ipcMain.handle("history:delete", (_e, id) => {
  const removedLast = history.some(entry => entry.id === id && entry.text === lastTranscript);
  saveHistory(history.filter((entry) => entry.id !== id));
  if (removedLast) lastTranscript = history[0]?.text || "";
  buildTrayMenu();
  return history;
});

ipcMain.handle("history:clear", async () => {
  const { response } = await dialog.showMessageBox(historyWin, {
    type: "warning", message: "Delete all transcriptions?",
    detail: "This cannot be undone.", buttons: ["Cancel", "Delete all"], defaultId: 0, cancelId: 0,
  });
  if (response !== 1) return history;
  saveHistory([]);
  lastTranscript = "";
  buildTrayMenu();
  return history;
});

ipcMain.handle("history:copy", (_e, text) => writeClipboard(text));

ipcMain.handle("stats:local", () => ({
  count: history.length,
  words: history.reduce((sum, entry) => sum + (entry.words || 0), 0),
  durationMs: history.reduce((sum, entry) => sum + (entry.durationMs || 0), 0),
  since: history.length ? history[history.length - 1].at : null,
}));

ipcMain.handle("soniox:usage", async (_e, days = 30) => {
  unlockApiKey();
  if (!config.apiKey) return { ok: false, message: "No API key" };
  const end = new Date();
  const start = new Date(end.getTime() - days * 86400000);
  const query = new URLSearchParams({
    start_time: start.toISOString(),
    end_time: end.toISOString(),
  });
  try {
    const res = await fetch(`https://api.soniox.com/v1/usage/summary?${query}`, {
      headers: { Authorization: `Bearer ${config.apiKey}` },
      signal: AbortSignal.timeout(10000),
    });
    if (!res.ok) return { ok: false, message: `HTTP ${res.status}` };
    const { total } = await res.json();
    return {
      ok: true,
      requests: total.total_num_requests,
      audioMs: total.total_input_audio_duration_ms,
      costUsd: Number(total.total_cost_usd),
      days: total.days,
      dailyCost: total.cost_usd.map(Number),
    };
  } catch (err) {
    return { ok: false, message: err.message };
  }
});

ipcMain.handle("soniox:verify", async (_e, apiKey) => {
  try {
    const res = await fetch("https://api.soniox.com/v1/models", {
      headers: { Authorization: `Bearer ${apiKey}` },
      signal: AbortSignal.timeout(10000),
    });
    if (!res.ok) return { ok: false, message: `HTTP ${res.status}` };
    const data = await res.json();
    const models = (data.models || data.data || [])
      .map((m) => m.id || m.name)
      .filter((id) => typeof id === "string" && id.startsWith("stt-rt-"));
    return { ok: true, models };
  } catch (err) {
    return { ok: false, message: err.message };
  }
});

ipcMain.handle("openrouter:verify-model", async (_e, { key, model }) => {
  const id = (model || "").trim();
  if (!id) return { ok: false, message: "Enter a model ID first." };
  try {
    // The per-model endpoint 404s even for live models; match against the list instead.
    const res = await fetch("https://openrouter.ai/api/v1/models", {
      headers: { Authorization: `Bearer ${key || config.openrouterKey}` },
      signal: AbortSignal.timeout(15000),
    });
    if (!res.ok) return { ok: false, message: `HTTP ${res.status}` };
    const { data } = await res.json();
    const hit = (data || []).find(m => m.id === id);
    if (!hit) {
      const author = id.split("/")[0];
      const available = (data || [])
        .map(m => m.id)
        .filter(mid => mid.startsWith(`${author}/`))
        .slice(0, 8);
      return { ok: false, message: "Model not found.", available };
    }
    return { ok: true, name: hit.name || id, contextLength: hit.context_length ?? null };
  } catch (err) {
    return { ok: false, message: err.message };
  }
});

const normalizeProvider = (name) => (name || "").toLowerCase().replace(/[^a-z0-9]/g, "");

ipcMain.handle("openrouter:verify-provider", async (_e, { key, model, provider }) => {
  const id = (model || "").trim();
  const wanted = parseCleanupProvider(provider);
  if (!id) return { ok: false, message: "Enter a model ID first." };
  if (!wanted) return { ok: true, auto: true };
  try {
    // Model IDs are URL-safe author/slug pairs; encoding the slash 404s.
    const res = await fetch(`https://openrouter.ai/api/v1/models/${id}/endpoints`, {
      headers: { Authorization: `Bearer ${key || config.openrouterKey}` },
      signal: AbortSignal.timeout(10000),
    });
    if (res.status === 404) return { ok: false, message: "Model not found." };
    if (!res.ok) return { ok: false, message: `HTTP ${res.status}` };
    const { data } = await res.json();
    const endpoints = data?.endpoints || [];
    const hit = endpoints.find(e =>
      (e.tag || "").toLowerCase() === wanted.name.toLowerCase()
      || (normalizeProvider(e.provider_name) === normalizeProvider(wanted.name)
        && (!wanted.quantization || (e.quantization || "").toLowerCase() === wanted.quantization.toLowerCase())));
    if (hit) return { ok: true, provider: hit.tag || hit.provider_name, quantization: hit.quantization || null };
    return {
      ok: false,
      message: `"${provider.trim()}" does not serve this model.`,
      available: [...new Set(endpoints.map(e => e.provider_name).filter(Boolean))],
    };
  } catch (err) {
    return { ok: false, message: err.message };
  }
});
ipcMain.handle("openrouter:verify", async (_e, apiKey) => {
  try {
    const res = await fetch("https://openrouter.ai/api/v1/auth/key", {
      headers: { Authorization: `Bearer ${apiKey}` },
      signal: AbortSignal.timeout(10000),
    });
    if (!res.ok) return { ok: false, message: `HTTP ${res.status}` };
    return { ok: true };
  } catch (err) {
    return { ok: false, message: err.message };
  }
});

ipcMain.handle("openrouter:usage", async () => {
  unlockApiKey();
  const local = { ...cleanupStats };
  if (!config.openrouterKey) return { ok: false, message: "No OpenRouter key", local };
  try {
    const res = await fetch("https://openrouter.ai/api/v1/auth/key", {
      headers: { Authorization: `Bearer ${config.openrouterKey}` },
      signal: AbortSignal.timeout(10000),
    });
    if (!res.ok) return { ok: false, message: `HTTP ${res.status}`, local };
    const { data } = await res.json();
    return {
      ok: true,
      keyUsage: Number(data?.usage) || 0,
      keyLimit: data?.limit == null ? null : Number(data.limit),
      local,
    };
  } catch (err) {
    return { ok: false, message: err.message, local };
  }
});

ipcMain.on("hotkey:capture", (_e, active) => {
  capturing = Boolean(active);
  clearTimeout(captureTimer);
  tapArmed = null;
  tapCount = 0;
  applyKeytap();
});

ipcMain.handle("open:console", () => shell.openExternal("https://console.soniox.com"));

ipcMain.handle("open:openrouter", () => shell.openExternal("https://openrouter.ai/activity"));

ipcMain.handle("open:experiments", async () => {
  try { fs.mkdirSync(EXPERIMENT_DIR, { recursive: true }); } catch { /* folder opens anyway if it exists */ }
  return shell.openPath(EXPERIMENT_DIR);
});

/* ------------------------------------ boot ---------------------------------- */

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else app.whenReady().then(() => {
  trace("when-ready");
  if (IS_MAC) app.dock?.hide();
  loadConfig();
  loadHistory();
  loadCleanupStats();
  trace("store-loaded");

  // The hotkey is the product; register it before anything that can wait a frame.
  registerHotkey();
  trace("hotkey-registered");

  // The surface is the only page allowed to reach hardware; nothing else is granted.
  session.defaultSession.setPermissionRequestHandler((contents, permission, callback) => {
    callback(permission === "media" && contents === surface?.webContents);
  });

  createSurface();
  const updateDisplay = () => {
    if (!surfaceDisplay) return;
    surfaceDisplay = screen.getAllDisplays().find(display => display.id === surfaceDisplay.id)
      || screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
    if (state !== "idle") layoutSurface();
  };
  screen.on("display-removed", updateDisplay);
  screen.on("display-metrics-changed", updateDisplay);

  tray = new Tray(trayIcon(false));
  tray.setToolTip("Transcriber");
  buildTrayMenu();

  applyLoginItem();
  trace("boot-done");

  if (process.env.TRANSCRIBER_AUTOTOGGLE) String(process.env.TRANSCRIBER_AUTOTOGGLE).split(",").forEach((ms) => setTimeout(toggle, Number(ms)));

  if (!encryptedKey) openSettings();
});

app.on("web-contents-created", (_event, contents) => {
  contents.setWindowOpenHandler(() => ({ action: "deny" }));
  contents.on("will-navigate", event => event.preventDefault());
});
app.on("second-instance", openSettings);
app.on("activate", openSettings);
app.on("window-all-closed", (e) => e.preventDefault());
app.on("before-quit", () => { quitting = true; });
app.on("will-quit", () => {
  globalShortcut.unregisterAll();
  keytap?.kill();
  if (persistTimer) flushConfig();
});
