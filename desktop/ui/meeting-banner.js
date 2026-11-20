const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const $ = (id) => document.getElementById(id);

const systemDark = matchMedia("(prefers-color-scheme: dark)");
let platformDark = null;

function applyTheme() {
  document.documentElement.dataset.theme = (platformDark ?? systemDark.matches) ? "dark" : "light";
}

systemDark.addEventListener("change", applyTheme);
applyTheme();

function render(meeting) {
  const title = meeting.title || meeting.source || "Meeting";
  const same = title.trim().toLowerCase() === (meeting.source || "").trim().toLowerCase();
  $("title").textContent = title;
  $("source").textContent = same ? "Meeting detected" : (meeting.source || "Meeting detected");
}

function apply(payload) {
  const pill = $("pill");
  if (typeof payload.dark === "boolean") {
    platformDark = payload.dark;
    applyTheme();
  }
  if (payload.edge) {
    document.documentElement.dataset.edge = payload.edge;
  }
  if (payload.state === "show" || payload.state === "update") {
    render(payload.meeting);
    requestAnimationFrame(() => pill.classList.remove("hidden"));
  } else if (payload.state === "hide") {
    pill.classList.add("hidden");
  }
}

listen("meeting-banner", ({ payload }) => apply(payload));
// A banner shown before this page loaded missed its event.
invoke("meeting_banner_current").then((payload) => payload && apply(payload));

$("start").addEventListener("click", () => invoke("meeting_banner_start"));
$("dismiss").addEventListener("click", () => invoke("meeting_banner_dismiss"));
