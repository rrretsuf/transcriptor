const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("flow", {
  onStart: (fn) => ipcRenderer.on("session:start", (_e, cfg) => fn(cfg)),
  onStop: (fn) => ipcRenderer.on("session:stop", () => fn()),
  onCancel: (fn) => ipcRenderer.on("session:cancel", () => fn()),
  result: (text) => ipcRenderer.send("session:result", text),
  error: (message) => ipcRenderer.send("session:error", message),
  autostop: () => ipcRenderer.send("session:autostop"),

  getConfig: () => ipcRenderer.invoke("config:get"),
  setConfig: (patch) => ipcRenderer.invoke("config:set", patch),
  permStatus: () => ipcRenderer.invoke("perm:status"),
  askMicrophone: () => ipcRenderer.invoke("perm:microphone"),
  askAccessibility: () => ipcRenderer.invoke("perm:accessibility"),
  verifyKey: (key) => ipcRenderer.invoke("soniox:verify", key),
});
