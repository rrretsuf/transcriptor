const {
  app, BrowserWindow, Tray, Menu, globalShortcut, clipboard, ipcMain,
  safeStorage, screen, shell, nativeImage, systemPreferences, Notification, session,
} = require("electron");
const { execFile } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const IS_MAC = process.platform === "darwin";
const CONFIG_PATH = path.join(app.getPath("userData"), "config.json");
const HISTORY_PATH = path.join(app.getPath("userData"), "history.json");
const HISTORY_LIMIT = 500;

const DEFAULTS = {
  apiKey: "",
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
  transcriptVisible: false,
  transcriptHeight: 180,
  saveHistory: true,
};

// Collapsed the surface is a bare capsule; open it grows into a transcript panel.
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

/* ---------------------------------- store ---------------------------------- */

function loadConfig() {
  try {
    const raw = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
    const { apiKeyEnc, ...rest } = raw;
    config = { ...DEFAULTS, ...rest };
    if (apiKeyEnc && safeStorage.isEncryptionAvailable()) {
      config.apiKey = safeStorage.decryptString(Buffer.from(apiKeyEnc, "base64"));
    } else if (raw.apiKey && safeStorage.isEncryptionAvailable()) {
      saveConfig();
    }
  } catch {
    config = { ...DEFAULTS };
  }
}

function saveConfig() {
  const { apiKey, ...rest } = config;
  const out = { ...rest };
  if (apiKey && safeStorage.isEncryptionAvailable()) {
    out.apiKeyEnc = safeStorage.encryptString(apiKey).toString("base64");
  } else if (apiKey) {
    out.apiKey = apiKey;
  }
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(out, null, 2));
}

// ponytail: one JSON file. Swap for sqlite only if a list this small ever feels slow.
function loadHistory() {
  try {
    history = JSON.parse(fs.readFileSync(HISTORY_PATH, "utf8"));
  } catch {
    history = [];
  }
}

function saveHistory() {
  fs.writeFileSync(HISTORY_PATH, JSON.stringify(history));
}

function recordTranscript(text, durationMs) {
  if (!config.saveHistory) return;
  history.unshift({
    id: `${Date.now()}-${history.length}`,
    text,
    at: Date.now(),
    durationMs,
    words: text.split(/\s+/).filter(Boolean).length,
  });
  history.length = Math.min(history.length, HISTORY_LIMIT);
  saveHistory();
  historyWin?.webContents.send("history:changed");
}

/* --------------------------------- geometry -------------------------------- */

function surfaceBounds() {
  const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
  const { x, y, width, height } = display.workArea;
  const open = config.transcriptVisible;

  if (config.position === "bottom") {
    const panel = Math.min(config.transcriptHeight, height - 2 * MARGIN - CAPSULE);
    const w = open ? PANEL_WIDTH : CAPSULE_LENGTH;
    const h = open ? CAPSULE + panel : CAPSULE;
    return { x: Math.round(x + (width - w) / 2), y: y + height - MARGIN - h, width: w, height: h };
  }

  const panel = Math.min(config.transcriptHeight, height - 2 * MARGIN);
  const w = open ? CAPSULE + PANEL_WIDTH : CAPSULE;
  const h = open ? Math.max(CAPSULE_LENGTH, panel) : CAPSULE_LENGTH;
  return {
    x: config.position === "left" ? x + MARGIN : x + width - MARGIN - w,
    y: Math.round(y + (height - h) / 2),
    width: w,
    height: h,
  };
}

function layoutSurface(animate = false) {
  surface.setBounds(surfaceBounds(), animate && IS_MAC);
  surface.webContents.send("surface:layout", {
    position: config.position,
    open: config.transcriptVisible,
    height: config.transcriptHeight,
  });
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
  surface.loadFile(path.join(__dirname, "renderer", "pill.html"));

  // Paint once off-screen so the first dictation appears fully rendered.
  surface.once("ready-to-show", () => {
    surface.setPosition(-2400, -2400);
    surface.showInactive();
    setTimeout(() => surface.hide(), 250);
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
  win.once("ready-to-show", () => {
    win.show();
    app.focus({ steal: true });
  });
  return win;
}

function openSettings() {
  if (settingsWin && !settingsWin.isDestroyed()) {
    settingsWin.show();
    settingsWin.focus();
    app.focus({ steal: true });
    return;
  }
  settingsWin = panelWindow("settings.html", { width: 580, height: 720, title: "Settings" });
  settingsWin.on("closed", () => { settingsWin = null; });
}

function openHistory() {
  if (historyWin && !historyWin.isDestroyed()) {
    historyWin.show();
    historyWin.focus();
    app.focus({ steal: true });
    return;
  }
  historyWin = panelWindow("history.html", { width: 620, height: 720, title: "Transcriptions" });
  historyWin.on("closed", () => { historyWin = null; });
}

/* ----------------------------------- tray ---------------------------------- */

function trayIcon(active) {
  const img = nativeImage.createFromPath(
    path.join(__dirname, "assets", active ? "trayActiveTemplate.png" : "trayTemplate.png")
  );
  img.setTemplateImage(true);
  return img;
}

function buildTrayMenu() {
  const label =
    state === "recording" ? "Stop dictation"
    : state === "finishing" ? "Finishing…"
    : "Start dictation";
  tray.setContextMenu(Menu.buildFromTemplate([
    { label, accelerator: config.hotkey, click: () => toggle(), enabled: state !== "finishing" },
    {
      label: "Copy last transcription",
      enabled: history.length > 0,
      click: () => clipboard.writeText(history[0].text),
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
  tray?.setImage(trayIcon(next !== "idle"));
  buildTrayMenu();
}

/* --------------------------------- dictation -------------------------------- */

function notify(title, body) {
  if (Notification.isSupported()) new Notification({ title, body, silent: true }).show();
}

const KEY_SYMBOLS = { Command: "⌘", Control: "⌃", Alt: "⌥", Shift: "⇧" };
const hotkeyLabel = () =>
  config.hotkey.split("+").map((part) => KEY_SYMBOLS[part] ?? part).join("");

function sessionConfig() {
  return {
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
  if (state === "recording") return stop();
  if (state !== "idle") return;

  if (!config.apiKey) {
    notify("Transcriber", "Add your Soniox API key in Settings first.");
    openSettings();
    return;
  }
  if (IS_MAC && systemPreferences.getMediaAccessStatus("microphone") !== "granted") {
    if (!(await systemPreferences.askForMediaAccess("microphone"))) {
      notify("Microphone blocked", "Allow microphone access to dictate.");
      openSettings();
      return;
    }
  }
  setState("recording");
  layoutSurface();
  surface.showInactive();
  surface.webContents.send("session:start", sessionConfig());
  globalShortcut.register("Escape", cancel);
}

function stop() {
  if (state !== "recording") return;
  setState("finishing");
  globalShortcut.unregister("Escape");
  surface.webContents.send("session:stop");
}

function cancel() {
  if (state === "idle") return;
  globalShortcut.unregister("Escape");
  surface.webContents.send("session:cancel");
  surface.hide();
  setState("idle");
}

function pasteAtCursor(text) {
  const previous = config.restoreClipboard ? clipboard.readText() : null;
  clipboard.writeText(text);
  if (!config.autoPaste) return;
  execFile("osascript", ["-e", 'tell application "System Events" to key code 9 using command down'], (err) => {
    if (err) notify("Paste failed", "Grant Accessibility permission in Settings to paste automatically.");
    if (previous !== null) setTimeout(() => clipboard.writeText(previous), 800);
  });
}

function registerHotkey() {
  globalShortcut.unregisterAll();
  if (!globalShortcut.register(config.hotkey, toggle)) {
    notify("Hotkey unavailable", `${config.hotkey} is already taken by another app.`);
  }
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

ipcMain.on("session:result", (_e, { text, durationMs }) => {
  surface.hide();
  setState("idle");
  const clean = (text || "").trim();
  if (!clean) return;
  recordTranscript(clean, durationMs);
  buildTrayMenu();
  pasteAtCursor(clean);
});

ipcMain.on("session:error", (_e, message) => {
  globalShortcut.unregister("Escape");
  setState("idle");
  const { x, y, width, height } = surface.getBounds();
  surface.setBounds({ x: Math.round(x + (width - 260) / 2), y, width: 260, height }, IS_MAC);
  setTimeout(() => surface.hide(), 2400);
  notify("Transcription failed", message);
});

ipcMain.on("session:autostop", () => stop());

ipcMain.on("surface:toggle", () => {
  config.transcriptVisible = !config.transcriptVisible;
  saveConfig();
  layoutSurface(true);
});

ipcMain.on("surface:resize", (_e, height) => {
  config.transcriptHeight = Math.max(PANEL_MIN, Math.round(height));
  layoutSurface();
});

ipcMain.on("surface:resized", () => saveConfig());

ipcMain.handle("config:get", () => ({ ...config, hasKey: Boolean(config.apiKey) }));

ipcMain.handle("config:set", (_e, patch) => {
  const hotkeyChanged = patch.hotkey && patch.hotkey !== config.hotkey;
  config = { ...config, ...patch };
  saveConfig();
  if (hotkeyChanged) registerHotkey();
  if (patch.position) layoutSurface();
  applyLoginItem();
  buildTrayMenu();
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
  history = history.filter((entry) => entry.id !== id);
  saveHistory();
  buildTrayMenu();
  return history;
});

ipcMain.handle("history:clear", () => {
  history = [];
  saveHistory();
  buildTrayMenu();
  return history;
});

ipcMain.handle("history:copy", (_e, text) => clipboard.writeText(text));

ipcMain.handle("stats:local", () => ({
  count: history.length,
  words: history.reduce((sum, entry) => sum + (entry.words || 0), 0),
  durationMs: history.reduce((sum, entry) => sum + (entry.durationMs || 0), 0),
  since: history.length ? history[history.length - 1].at : null,
}));

ipcMain.handle("soniox:usage", async (_e, days = 30) => {
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

ipcMain.handle("open:console", () => shell.openExternal("https://console.soniox.com"));

/* ------------------------------------ boot ---------------------------------- */

if (!app.requestSingleInstanceLock()) app.quit();

app.whenReady().then(() => {
  if (IS_MAC) app.dock?.hide();
  loadConfig();
  loadHistory();

  // The surface is the only page allowed to reach hardware; nothing else is granted.
  session.defaultSession.setPermissionRequestHandler((contents, permission, callback) => {
    callback(permission === "media" && contents === surface?.webContents);
  });

  createSurface();

  tray = new Tray(trayIcon(false));
  tray.setToolTip("Transcriber");
  buildTrayMenu();

  registerHotkey();
  applyLoginItem();

  if (!config.apiKey) openSettings();
});

app.on("window-all-closed", (e) => e.preventDefault());
app.on("will-quit", () => globalShortcut.unregisterAll());
