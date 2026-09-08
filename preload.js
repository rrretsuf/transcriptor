const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("app", {
  onStart: (fn) => ipcRenderer.on("session:start", (_e, cfg) => fn(cfg)),
  onStop: (fn) => ipcRenderer.on("session:stop", () => fn()),
  onCancel: (fn) => ipcRenderer.on("session:cancel", () => fn()),
  onLayout: (fn) => ipcRenderer.on("surface:layout", (_e, layout) => fn(layout)),
  onHistoryChanged: (fn) => ipcRenderer.on("history:changed", () => fn()),

  result: (payload) => ipcRenderer.send("session:result", payload),
  error: (message) => ipcRenderer.send("session:error", message),
  autostop: () => ipcRenderer.send("session:autostop"),
  toggleTranscript: () => ipcRenderer.send("surface:toggle"),
  resizeTranscript: (height) => ipcRenderer.send("surface:resize", height),
  commitResize: () => ipcRenderer.send("surface:resized"),

  getConfig: () => ipcRenderer.invoke("config:get"),
  setConfig: (patch) => ipcRenderer.invoke("config:set", patch),
  permStatus: () => ipcRenderer.invoke("perm:status"),
  askMicrophone: () => ipcRenderer.invoke("perm:microphone"),
  askAccessibility: () => ipcRenderer.invoke("perm:accessibility"),
  verifyKey: (key) => ipcRenderer.invoke("soniox:verify", key),
  usage: (days) => ipcRenderer.invoke("soniox:usage", days),
  localStats: () => ipcRenderer.invoke("stats:local"),
  openConsole: () => ipcRenderer.invoke("open:console"),

  historyList: () => ipcRenderer.invoke("history:list"),
  historyDelete: (id) => ipcRenderer.invoke("history:delete", id),
  historyClear: () => ipcRenderer.invoke("history:clear"),
  historyCopy: (text) => ipcRenderer.invoke("history:copy", text),
});
