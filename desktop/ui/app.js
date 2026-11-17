const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const $ = (id) => document.getElementById(id);
const all = (selector, root = document) => [...root.querySelectorAll(selector)];
const show = (element, visible) => { element.hidden = !visible; };

let snapshot;
let history = [];

/* -------------------------------- appearance ------------------------------- */

function applyAppearance() {
  const { platform } = snapshot;
  const root = document.documentElement;
  root.dataset.os = platform.os;
  if (platform.mica) root.dataset.mica = "";
  if (platform.accent) root.style.setProperty("--accent", platform.accent);
  const system = matchMedia("(prefers-color-scheme: dark)");
  const setTheme = () => { root.dataset.theme = (platform.dark ?? system.matches) ? "dark" : "light"; };
  system.addEventListener("change", setTheme);
  setTheme();
}

/* ---------------------------------- hotkey --------------------------------- */

const keyNames = { ArrowUp: "Up", ArrowDown: "Down", ArrowLeft: "Left", ArrowRight: "Right", Backquote: "`", Minus: "-", Equal: "=" };

/** A key press as the accelerator the core stores: modifiers first, one key last. */
function accelerator(event) {
  if (["Control", "Shift", "Alt", "Meta", "OS"].includes(event.key)) return null;
  const code = event.code;
  const key = code.startsWith("Key") ? code.slice(3) : code.startsWith("Digit") ? code.slice(5) : keyNames[code] ?? code;
  const parts = [];
  if (event.ctrlKey) parts.push("Control");
  if (event.altKey) parts.push("Alt");
  if (event.shiftKey) parts.push("Shift");
  if (event.metaKey) parts.push("Super");
  return [...parts, key].join("+");
}

let hotkeyRefused = "";

/** Click, press the combination, done. Escape leaves it as it was. */
function hotkeyRecorder(button) {
  const render = () => {
    button.textContent = snapshot.hotkeyLabel;
    button.classList.remove("recording");
    button.disabled = snapshot.desktopOwnsHotkey;
  };
  const stop = () => {
    removeEventListener("keydown", onKey, true);
    button.removeEventListener("blur", stop);
    render();
  };
  const onKey = async (event) => {
    event.preventDefault();
    event.stopPropagation();
    if (event.key === "Escape") return stop();
    const hotkey = accelerator(event);
    if (!hotkey) return;
    stop();
    try {
      await invoke("save_config", { config: { ...snapshot.config, hotkey } });
      hotkeyRefused = "";
    } catch (message) {
      hotkeyRefused = message;
    }
    await refresh();
  };
  button.addEventListener("click", () => {
    if (button.classList.contains("recording")) return stop();
    button.classList.add("recording");
    button.textContent = "Press keys…";
    addEventListener("keydown", onKey, true);
    button.addEventListener("blur", stop);
  });
  return render;
}

const renderHotkeys = [];

function renderHotkey() {
  renderHotkeys.forEach((render) => render());
  all(".hotkey-label").forEach((label) => { label.textContent = snapshot.hotkeyLabel; });
  const wayland = snapshot.hotkeyProblem === "wayland";
  const note = $("wayland-note");
  if (wayland) {
    note.innerHTML = "This desktop keeps global hotkeys to itself. In your system's keyboard settings, add a custom shortcut that runs:<code></code>";
    note.querySelector("code").textContent = snapshot.toggleCommand;
  } else if (snapshot.desktopOwnsHotkey) {
    note.textContent = "Your desktop manages this shortcut. Change it in the system's keyboard settings.";
  }
  show(note, wayland || snapshot.desktopOwnsHotkey);
  show($("onboarding-hotkey"), !wayland);
  show($("onboarding-hotkey-hint"), !wayland && !snapshot.desktopOwnsHotkey);
  const problem = wayland ? `Bind a key to: ${snapshot.toggleCommand}` : hotkeyRefused || snapshot.hotkeyProblem;
  for (const id of ["hotkey-problem", "onboarding-hotkey-problem"]) {
    $(id).textContent = problem ?? "";
    show($(id), Boolean(problem) && !(wayland && id.startsWith("onboarding")));
  }
}

/* -------------------------------- onboarding ------------------------------- */

const steps = ["key", "hotkey", "try", "done"];

function showStep(name) {
  all(".step").forEach((step) => show(step, step.dataset.step === name));
  all(".steps i").forEach((dot, index) => dot.classList.toggle("on", index === steps.indexOf(name)));
  if (name === "key") $("key-input").focus();
  if (name === "try") $("try-text").focus();
}

function setUpOnboarding() {
  $("key-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = event.target.querySelector("button");
    button.disabled = true;
    button.textContent = "Checking…";
    try {
      await invoke("save_key", { key: $("key-input").value });
      await refresh();
      showStep("hotkey");
    } catch (message) {
      $("key-problem").textContent = message;
      show($("key-problem"), true);
    }
    button.disabled = false;
    button.textContent = "Continue";
  });
  all("[data-next]").forEach((button) => button.addEventListener("click", () => {
    showStep(steps[steps.indexOf(button.closest(".step").dataset.step) + 1]);
  }));
  $("try-text").addEventListener("input", () => {
    const worked = $("try-text").value.trim().length > 0;
    show($("try-success"), worked);
    $("try-next").textContent = worked ? "Continue" : "Skip for now";
  });
  $("onboarding-finish").addEventListener("click", async () => {
    await invoke("finish_onboarding");
    await refresh();
    show($("onboarding"), false);
    show($("shell"), true);
  });
  all(".tray-name").forEach((name) => {
    name.textContent = snapshot.platform.os === "windows" ? "notification area, next to the clock" : "system tray";
  });
}

/* --------------------------------- history --------------------------------- */

const PAGE = 80;
let filter = "all";
let shown = PAGE;
const dateTime = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
const day = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" });
const time = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });

/** "Oct 13 · 14:05 – 15:12" */
const span = (start, end) => `${day.format(start)} · ${time.format(start)} – ${time.format(end)}`;

function duration(ms) {
  const seconds = Math.round(ms / 1000);
  const [h, m, s] = [Math.floor(seconds / 3600), Math.floor((seconds % 3600) / 60), seconds % 60];
  return h ? `${h}h ${m}m` : m ? `${m}m ${s}s` : `${s}s`;
}

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

const icon = (name) => `<svg><use href="#i-${name}" /></svg>`;

function entryRow(entry) {
  const row = element("div", "entry");
  const body = element("div", "body");
  if (entry.title) {
    const name = element("div", `name ${entry.kind}`);
    name.innerHTML = icon(entry.kind === "meeting" ? "record" : "file");
    name.append(element("span", "", entry.title));
    body.append(name);
  }
  body.append(element("div", "text", entry.text));
  const facts = [entry.startedAt ? span(entry.startedAt, entry.at) : dateTime.format(entry.at)];
  if (entry.app) facts.push(entry.app);
  if (entry.words != null) facts.push(`${entry.words} words`);
  if (entry.durationMs != null) facts.push(duration(entry.durationMs));
  const meta = element("div", "meta", facts.join(" · "));
  body.append(meta);
  const remove = element("button", "delete");
  remove.title = "Delete";
  remove.innerHTML = icon("trash");
  remove.addEventListener("click", async (event) => {
    event.stopPropagation();
    await invoke("delete_entry", { id: entry.id });
    await loadHistory();
  });
  row.append(body, remove);
  row.addEventListener("click", async () => {
    if (getSelection().toString()) return;
    await invoke("copy", { text: entry.text });
    row.classList.add("copied");
    meta.innerHTML = "<b>Copied</b>";
    setTimeout(() => {
      row.classList.remove("copied");
      meta.textContent = facts.join(" · ");
    }, 1200);
  });
  return row;
}

function renderHistory() {
  const query = $("history-search").value.trim().toLowerCase();
  const kind = history.filter((entry) => filter === "all" || entry.kind === filter);
  const matches = query
    ? kind.filter((entry) => entry.text.toLowerCase().includes(query) || entry.title?.toLowerCase().includes(query))
    : kind;
  const list = $("history-list");
  list.replaceChildren(...matches.slice(0, shown).map(entryRow));
  show(list, matches.length > 0);
  show($("history-empty"), matches.length === 0);
  if (matches.length) return;
  const [title, text] = query ? [`No results for “${query}”`, "Check the spelling or try another word."]
    : filter === "meeting" ? ["No meetings", "Start one from Meeting in the sidebar."]
    : ["No transcriptions", `Press ${snapshot.hotkeyLabel} and start talking.`];
  $("history-empty").querySelector("h3").textContent = title;
  $("history-empty").querySelector("p").textContent = text;
}

async function loadHistory() {
  history = await invoke("history");
  renderHistory();
  renderUsage();
}

function setUpHistory() {
  $("history-search").addEventListener("input", () => { shown = PAGE; renderHistory(); });
  all("#history-filter button").forEach((button) => button.addEventListener("click", () => {
    filter = button.dataset.filter;
    shown = PAGE;
    all("#history-filter button").forEach((other) => other.classList.toggle("selected", other === button));
    renderHistory();
  }));
  const list = $("history-list");
  list.addEventListener("scroll", () => {
    if (list.scrollTop + list.clientHeight < list.scrollHeight - 400 || shown >= history.length) return;
    shown += PAGE;
    renderHistory();
  });
}

/* --------------------------------- meeting --------------------------------- */

let meeting;
const words = (text) => `${text.split(/\s+/).filter(Boolean).length} words`;

function clock() {
  if (!meeting) return;
  const ms = meeting.elapsedMs + (meeting.runningSince ? Date.now() - meeting.runningSince : 0);
  const seconds = Math.floor(ms / 1000);
  const pad = (n) => String(n).padStart(2, "0");
  $("meeting-clock").textContent = `${Math.floor(seconds / 3600)}:${pad(Math.floor(seconds / 60) % 60)}:${pad(seconds % 60)}`;
}

function renderMeeting(next) {
  meeting = next;
  const { status } = meeting;
  const live = ["recording", "paused", "finishing"].includes(status);
  show($("meeting-idle"), status === "idle");
  show($("meeting-live"), live);
  show($("meeting-done"), status === "done");
  show($("nav-meeting-dot"), status === "recording");
  if (document.activeElement !== $("meeting-title")) $("meeting-title").value = meeting.title;
  if (live) {
    $("meeting-dot").classList.toggle("on", status === "recording");
    $("meeting-state").textContent = { recording: "Recording meeting", paused: "Paused", finishing: "Finishing…" }[status];
    const text = $("meeting-text");
    const atBottom = text.scrollTop + text.clientHeight > text.scrollHeight - 40;
    text.textContent = meeting.transcript || "Words appear here as people speak.";
    text.classList.toggle("placeholder", !meeting.transcript);
    if (atBottom) text.scrollTop = text.scrollHeight;
    $("meeting-pause").textContent = status === "paused" ? "Continue" : "Pause";
    $("meeting-pause").disabled = $("meeting-end").disabled = status === "finishing";
    $("meeting-problem").textContent = meeting.problem ?? "";
    show($("meeting-problem"), Boolean(meeting.problem));
    clock();
  }
  if (status === "done") {
    $("meeting-span").textContent = span(meeting.startedAt, meeting.endedAt);
    $("meeting-final").textContent = meeting.transcript || "No speech was captured.";
    $("meeting-final").classList.toggle("placeholder", !meeting.transcript);
    $("meeting-words").textContent = words(meeting.transcript);
  }
}

function setUpMeeting() {
  all("[data-meeting]").forEach((button) => button.addEventListener("click", () => {
    invoke("meeting_do", { action: button.dataset.meeting });
  }));
  $("meeting-title").addEventListener("change", (event) => invoke("meeting_do", { action: "title", title: event.target.value }));
  $("meeting-title").addEventListener("keydown", (event) => { if (event.key === "Enter") event.target.blur(); });
  $("meeting-what").textContent = snapshot.systemAudio
    ? "Your microphone and everything the computer plays, with or without headphones."
    : "Your microphone. This system has no way to record what the computer plays.";
  setInterval(clock, 500);
  listen("meeting", (event) => renderMeeting(event.payload));
}

/* ----------------------------------- file ---------------------------------- */

function renderFile(file) {
  show($("file-drop"), file.status === "idle");
  show($("file-working"), file.status === "working");
  show($("file-done"), file.status === "done");
  show($("file-failed"), file.status === "failed");
  if (file.status === "working") {
    $("file-name").textContent = file.name;
    $("file-stage").textContent = file.stage;
  }
  if (file.status === "done") {
    $("file-text").textContent = file.text;
    $("file-words").textContent = words(file.text);
  }
  if (file.status === "failed") $("file-problem").textContent = file.message;
}

function setUpFile() {
  $("file-drop").addEventListener("click", async () => {
    const path = await window.__TAURI__.dialog.open({
      multiple: false,
      filters: [{ name: "Audio or video", extensions: ["mp3", "wav", "m4a", "flac", "ogg", "aac", "aiff", "amr", "mp4", "mov", "webm", "mkv", "opus", "wma"] }],
    });
    if (path) invoke("file_start", { path });
  });
  all("[data-file]").forEach((button) => button.addEventListener("click", () => invoke("file_reset")));
  listen("file", (event) => renderFile(event.payload));
  window.__TAURI__.webview.getCurrentWebview().onDragDropEvent(({ payload }) => {
    const idle = !$("file-drop").hidden && !$("shell").hidden;
    $("file-drop").classList.toggle("over", payload.type === "over" || payload.type === "enter");
    if (payload.type !== "drop" || !payload.paths.length) return;
    if (!idle) navigate("file");
    invoke("file_start", { path: payload.paths[0] });
  });
}

/* --------------------------------- settings -------------------------------- */

const languages = ["af", "sq", "ar", "az", "eu", "be", "bn", "bs", "bg", "ca", "zh", "hr", "cs", "da", "nl", "en", "et", "fi",
  "fr", "gl", "de", "el", "gu", "he", "hi", "hu", "id", "it", "ja", "kn", "kk", "ko", "lv", "lt", "mk", "ms",
  "ml", "mr", "no", "fa", "pl", "pt", "pa", "ro", "ru", "sr", "sk", "sl", "es", "sw", "sv", "tl", "ta", "te",
  "th", "tr", "uk", "ur", "vi", "cy"];
const languageNames = new Intl.DisplayNames(undefined, { type: "language" });
const languageName = (code) => {
  const name = languageNames.of(code) ?? code.toUpperCase();
  return name[0].toUpperCase() + name.slice(1);
};
languages.sort((a, b) => languageName(a).localeCompare(languageName(b)));

async function saveConfig(change) {
  snapshot.config = { ...snapshot.config, ...change };
  try {
    await invoke("save_config", { config: snapshot.config });
  } catch (message) {
    banner(message);
  }
}

function renderLanguages() {
  const hints = snapshot.config.languageHints;
  const chips = hints.map((code) => {
    const chip = element("button", "", languageName(code));
    chip.title = `Remove ${languageName(code)}`;
    chip.insertAdjacentHTML("beforeend", icon("x"));
    chip.addEventListener("click", async () => {
      await saveConfig({ languageHints: hints.filter((hint) => hint !== code) });
      renderLanguages();
    });
    return chip;
  });
  const add = element("select");
  add.append(new Option("Add…", ""), ...languages.filter((code) => !hints.includes(code)).map((code) => new Option(languageName(code), code)));
  add.addEventListener("change", async () => {
    await saveConfig({ languageHints: [...hints, add.value] });
    renderLanguages();
  });
  $("languages").replaceChildren(...chips, add);
}

function renderSettings() {
  const { config } = snapshot;
  all("[data-config]").forEach((input) => {
    if (document.activeElement === input) return;
    const value = config[input.dataset.config];
    if (input.type === "checkbox") input.checked = value;
    else input.value = value;
  });
  renderLanguages();
  show($("settings-key-saved"), snapshot.hasKey && !$("settings-key").value);
  $("key-footnote").textContent = snapshot.platform.os === "windows"
    ? "Stored in Windows Credential Manager, never in a file."
    : "Stored in your system keyring, never in the settings file.";
  $("about").textContent = `Transcriptor ${snapshot.version}. Audio goes to Soniox and nowhere else.`;
}

function renderUsage() {
  const totalWords = history.reduce((sum, entry) => sum + (entry.words ?? 0), 0);
  const seconds = history.reduce((sum, entry) => sum + (entry.durationMs ?? 0), 0) / 1000;
  const startOfDay = new Date().setHours(0, 0, 0, 0);
  const number = new Intl.NumberFormat();
  const tiles = [
    [number.format(history.length), "Transcriptions"],
    [number.format(totalWords), "Words"],
    [`${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`, "Spoken"],
    [seconds ? Math.round(totalWords / seconds * 60) : 0, "Words / min"],
    [number.format(history.filter((entry) => entry.at >= startOfDay).length), "Today"],
    // Soniox real-time list price: $0.12 per streamed hour.
    [`$${(seconds / 3600 * 0.12).toFixed(2)}`, "Soniox spend (est.)"],
  ];
  $("usage").replaceChildren(...tiles.map(([value, label]) => {
    const tile = element("div", "tile");
    tile.append(element("b", "", value), element("span", "", label));
    return tile;
  }));
}

function setUpSettings() {
  $("translate-to").append(new Option("Off", ""), ...languages.map((code) => new Option(languageName(code), code)));
  all("[data-config]").forEach((input) => input.addEventListener("change", () => {
    const value = input.type === "checkbox" ? input.checked : input.type === "number" ? Math.max(0, Number(input.value) || 0) : input.value;
    saveConfig({ [input.dataset.config]: value });
  }));
  $("settings-key").addEventListener("input", () => {
    show($("settings-key-save"), $("settings-key").value.length > 0);
    show($("settings-key-saved"), snapshot.hasKey && !$("settings-key").value);
  });
  $("settings-key-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const save = $("settings-key-save");
    save.disabled = true;
    save.textContent = "Checking…";
    try {
      await invoke("save_key", { key: $("settings-key").value });
      $("settings-key").value = "";
      show($("settings-key-problem"), false);
      show(save, false);
    } catch (message) {
      $("settings-key-problem").textContent = message;
      show($("settings-key-problem"), true);
    }
    save.disabled = false;
    save.textContent = "Save";
    await refresh();
  });
}

/* ---------------------------------- shell ---------------------------------- */

function navigate(view) {
  if (!$(`view-${view}`)) return;
  all(".view").forEach((section) => show(section, section.id === `view-${view}`));
  all("nav [data-view]").forEach((button) => button.classList.toggle("selected", button.dataset.view === view));
}

function banner(message) {
  $("banner").textContent = message;
  show($("banner"), Boolean(message));
}

function renderPhase(phase) {
  $("dictate").classList.toggle("active", phase !== "idle");
  $("dictate").disabled = phase === "finishing";
  $("dictate-label").textContent = { idle: "Start Dictation", recording: "Stop Dictation", finishing: "Finishing…" }[phase];
}

async function refresh() {
  snapshot = await invoke("snapshot");
  renderHotkey();
  renderSettings();
  renderPhase(snapshot.phase);
}

async function start() {
  snapshot = await invoke("snapshot");
  applyAppearance();
  renderHotkeys.push(hotkeyRecorder($("settings-hotkey")), hotkeyRecorder($("onboarding-hotkey")));
  setUpOnboarding();
  setUpHistory();
  setUpMeeting();
  setUpFile();
  setUpSettings();
  await refresh();
  await loadHistory();
  renderMeeting(await invoke("meeting_get"));
  renderFile(await invoke("file_get"));

  all("nav [data-view]").forEach((button) => button.addEventListener("click", () => navigate(button.dataset.view)));
  $("dictate").addEventListener("click", () => invoke("toggle"));
  all("[data-url]").forEach((link) => link.addEventListener("click", () => window.__TAURI__.opener.openUrl(link.dataset.url)));
  all("[data-copy]").forEach((button) => button.addEventListener("click", async () => {
    await invoke("copy", { text: $(button.dataset.copy).textContent });
    button.textContent = "Copied";
    setTimeout(() => { button.textContent = "Copy"; }, 1400);
  }));
  listen("navigate", (event) => navigate(event.payload));
  listen("history", loadHistory);
  listen("hotkey", refresh);
  listen("state", (event) => renderPhase(event.payload.phase));
  addEventListener("focus", refresh);

  if (snapshot.unreadable.length) {
    banner(`Your ${snapshot.unreadable.join(" and ")} file could not be read. It is kept as it is and will not be overwritten.`);
  }
  navigate(snapshot.view);
  const onboarding = !snapshot.config.onboarded;
  show($("onboarding"), onboarding);
  show($("shell"), !onboarding);
  if (onboarding) showStep(snapshot.hasKey ? "hotkey" : "key");
}

start();
