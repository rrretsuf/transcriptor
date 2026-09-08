const {
  app, BrowserWindow, Tray, Menu, globalShortcut, clipboard, ipcMain,
  safeStorage, screen, shell, nativeImage, systemPreferences, Notification, session,
} = require("electron");
const { execFile } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const IS_MAC = process.platform === "darwin";
const CONFIG_PATH = path.join(app.getPath("userData"), "config.json");

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
};

let config = { ...DEFAULTS };
let tray = null;
let pill = null;
let settingsWin = null;
let state = "idle";
let lastTranscript = "";

/* ---------------------------------- config --------------------------------- */

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

const KEY_SYMBOLS = { Command: "\u2318", Control: "\u2303", Alt: "\u2325", Shift: "\u21e7", Space: "Space" };

function hotkeyLabel() {
  return config.hotkey.split("+").map((part) => KEY_SYMBOLS[part] ?? part).join("");
}

function sessionConfig() {
  return {
    hotkeyLabel: hotkeyLabel(),
    apiKey: config.apiKey,
    model: config.model,
    languageHints: config.languageHints,
    context: config.context,
    translateTo: config.translateTo,
    silenceStopMs: config.silenceStopMs,
  };
}

/* ---------------------------------- windows -------------------------------- */

function createPill() {
  pill = new BrowserWindow({
    width: 560,
    height: 220,
    show: false,
    frame: false,
    transparent: true,
    hasShadow: false,
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
  pill.setAlwaysOnTop(true, "screen-saver");
  pill.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  pill.setIgnoreMouseEvents(true, { forward: false });
  pill.loadFile(path.join(__dirname, "renderer", "pill.html"));

  // Paint once off-screen so the first dictation appears fully rendered.
  pill.once("ready-to-show", () => {
    pill.setPosition(-2400, -2400);
    pill.showInactive();
    setTimeout(() => pill.hide(), 250);
  });
}

function placePill() {
  const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
  const { x, y, width, height } = display.workArea;
  const [w, h] = pill.getSize();
  pill.setPosition(Math.round(x + (width - w) / 2), Math.round(y + height - h - 24));
}

function openSettings() {
  if (settingsWin && !settingsWin.isDestroyed()) {
    settingsWin.show();
    settingsWin.focus();
    app.focus({ steal: true });
    return;
  }
  settingsWin = new BrowserWindow({
    width: 620,
    height: 820,
    minWidth: 560,
    minHeight: 560,
    title: "Soniox Flow",
    titleBarStyle: IS_MAC ? "hiddenInset" : "default",
    backgroundColor: "#00000000",
    vibrancy: IS_MAC ? "under-window" : undefined,
    show: false,
    webPreferences: { preload: path.join(__dirname, "preload.js") },
  });
  settingsWin.loadFile(path.join(__dirname, "renderer", "settings.html"));
  settingsWin.once("ready-to-show", () => {
    settingsWin.show();
    app.focus({ steal: true });
  });
  settingsWin.on("closed", () => { settingsWin = null; });
}

/* ----------------------------------- tray ---------------------------------- */

function trayIcon(active) {
  const file = active ? "trayActiveTemplate.png" : "trayTemplate.png";
  const img = nativeImage.createFromPath(path.join(__dirname, "assets", file));
  img.setTemplateImage(true);
  return img;
}

function buildTrayMenu() {
  const label =
    state === "recording" ? "Stop dictation"
    : state === "finishing" ? "Finishing…"
    : "Start dictation";
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: `Soniox Flow — ${state}`, enabled: false },
    { type: "separator" },
    { label, accelerator: config.hotkey, click: () => toggle(), enabled: state !== "finishing" },
    {
      label: "Copy last transcript",
      enabled: Boolean(lastTranscript),
      click: () => clipboard.writeText(lastTranscript),
    },
    { type: "separator" },
    { label: "Settings…", accelerator: "Command+,", click: openSettings },
    { label: "Soniox usage & billing", click: () => shell.openExternal("https://console.soniox.com") },
    { type: "separator" },
    { label: "Quit", accelerator: "Command+Q", click: () => app.quit() },
  ]));
}

function setState(next) {
  state = next;
  if (tray) {
    tray.setImage(trayIcon(next !== "idle"));
    buildTrayMenu();
  }
}

/* --------------------------------- dictation -------------------------------- */

function notify(title, body) {
  if (Notification.isSupported()) new Notification({ title, body, silent: true }).show();
}

async function toggle() {
  if (state === "recording") return stop();
  if (state !== "idle") return;

  if (!config.apiKey) {
    notify("Soniox Flow", "Add your Soniox API key in Settings first.");
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
  placePill();
  pill.showInactive();
  pill.webContents.send("session:start", sessionConfig());
  globalShortcut.register("Escape", cancel);
}

function stop() {
  if (state !== "recording") return;
  setState("finishing");
  globalShortcut.unregister("Escape");
  pill.webContents.send("session:stop");
}

function cancel() {
  if (state === "idle") return;
  globalShortcut.unregister("Escape");
  pill.webContents.send("session:cancel");
  pill.hide();
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

function applyLoginItem() {
  try {
    if (app.getLoginItemSettings().openAtLogin === config.launchAtLogin) return;
    app.setLoginItemSettings({ openAtLogin: config.launchAtLogin });
  } catch {
    /* unsigned dev builds cannot register a login item */
  }
}

function registerHotkey() {
  globalShortcut.unregisterAll();
  const ok = globalShortcut.register(config.hotkey, toggle);
  if (!ok) notify("Hotkey unavailable", `${config.hotkey} is already taken by another app.`);
  return ok;
}

/* ------------------------------------ ipc ----------------------------------- */

ipcMain.on("session:result", (_e, text) => {
  pill.hide();
  setState("idle");
  const clean = (text || "").trim();
  if (!clean) return;
  lastTranscript = clean;
  buildTrayMenu();
  pasteAtCursor(clean);
});

ipcMain.on("session:error", (_e, message) => {
  globalShortcut.unregister("Escape");
  setState("idle");
  setTimeout(() => pill.hide(), 2200);
  notify("Transcription failed", message);
});

ipcMain.on("session:autostop", () => stop());

ipcMain.handle("config:get", () => ({ ...config, hasKey: Boolean(config.apiKey) }));

ipcMain.handle("config:set", (_e, patch) => {
  const hotkeyChanged = patch.hotkey && patch.hotkey !== config.hotkey;
  config = { ...config, ...patch };
  saveConfig();
  if (hotkeyChanged) registerHotkey();
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

/* ------------------------------------ boot ---------------------------------- */

if (!app.requestSingleInstanceLock()) app.quit();

app.whenReady().then(() => {
  if (IS_MAC) app.dock?.hide();
  loadConfig();

  // The pill is the only page allowed to reach hardware; nothing else is granted.
  session.defaultSession.setPermissionRequestHandler((contents, permission, callback) => {
    callback(permission === "media" && contents === pill?.webContents);
  });

  createPill();

  tray = new Tray(trayIcon(false));
  tray.setToolTip("Soniox Flow");
  buildTrayMenu();

  registerHotkey();
  applyLoginItem();

  if (!config.apiKey) openSettings();
});

app.on("window-all-closed", (e) => e.preventDefault());
app.on("will-quit", () => globalShortcut.unregisterAll());
