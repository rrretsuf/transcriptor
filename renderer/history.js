const relative = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
const UNITS = [["year", 31536000], ["month", 2592000], ["day", 86400], ["hour", 3600], ["minute", 60]];

function ago(timestamp) {
  const seconds = (timestamp - Date.now()) / 1000;
  for (const [unit, size] of UNITS) {
    if (Math.abs(seconds) >= size) return relative.format(Math.round(seconds / size), unit);
  }
  return relative.format(Math.round(seconds), "second");
}

const list = document.getElementById("list");
const search = document.getElementById("search");
const summary = document.getElementById("summary");
let entries = [];
let reloadVersion = 0;
const expanded = new Set();

function renderSummary() {
  if (!entries.length) {
    summary.textContent = "Your saved transcriptions appear here.";
    return;
  }
  const words = entries.reduce((sum, entry) => sum + (entry.words || 0), 0);
  const minutes = Math.round(entries.reduce((sum, entry) => sum + (entry.durationMs || 0), 0) / 60000);
  summary.innerHTML =
    `<b>${entries.length.toLocaleString()}</b> dictations · <b>${words.toLocaleString()}</b> words · <b>${minutes}</b> min spoken`;
}

function empty(title, note) {
  const box = document.createElement("div");
  box.className = "empty";
  const heading = document.createElement("b");
  heading.textContent = title;
  box.append(heading, document.createTextNode(note));
  list.replaceChildren(box);
}

function render() {
  const query = search.value.trim().toLowerCase();
  const shown = query
    ? entries.filter((entry) => entry.text.toLowerCase().includes(query))
    : entries;

  document.getElementById("clear").disabled = !entries.length;
  renderSummary();

  if (!entries.length) return empty("Nothing yet", `Press your hotkey and start talking.`);
  if (!shown.length) return empty("No matches", `Nothing contains “${search.value.trim()}”.`);

  list.innerHTML = "";
  const fragment = document.createDocumentFragment();
  shown.forEach((entry) => {
    const row = document.createElement("article");
    row.className = "entry";
    row.tabIndex = 0;
    row.dataset.id = entry.id;
    row.setAttribute("aria-label", "Transcription");
    row.setAttribute("aria-expanded", String(expanded.has(entry.id)));
    row.innerHTML = `
      <div class="entry-meta">
        <span>${ago(entry.at)}</span>
        <span>·</span>
        <span><span class="mono">${Math.round((entry.durationMs || 0) / 1000)}</span>s</span>
        <span>·</span>
        <span><span class="mono">${entry.words || 0}</span> words</span>
        <span class="spacer"></span>
        <span class="entry-actions">
          <button data-act="copy">Copy</button>
          <button data-act="delete">Delete</button>
        </span>
      </div>
      <div class="entry-text"></div>`;
    row.querySelector(".entry-text").textContent = entry.text;

    row.onclick = async (event) => {
      const action = event.target.dataset?.act;
      if (action === "copy") {
        try { await window.app.historyCopy(entry.text); }
        catch { return showError("Could not copy this transcription."); }
        event.target.textContent = "Copied";
        setTimeout(() => { event.target.textContent = "Copy"; }, 1200);
        return;
      }
      if (action === "delete") {
        try {
          entries = await window.app.historyDelete(entry.id);
          expanded.delete(entry.id);
          render();
        } catch { showError("Could not delete this transcription. It has been kept."); }
        return;
      }
      if (window.getSelection().toString()) return;
      if (expanded.has(entry.id)) expanded.delete(entry.id);
      else expanded.add(entry.id);
      row.setAttribute("aria-expanded", String(expanded.has(entry.id)));
    };
    row.onkeydown = event => {
      if (event.target === row && ["Enter", " "].includes(event.key)) {
        event.preventDefault();
        row.click();
      }
    };
    fragment.appendChild(row);
  });
  list.appendChild(fragment);
}

function showError(message = "") {
  document.getElementById("historyStatus").textContent = message;
  document.getElementById("historyStatus").hidden = !message;
}

async function reload() {
  const version = ++reloadVersion;
  try {
    const next = await window.app.historyList();
    if (version !== reloadVersion) return;
    const main = document.querySelector("main");
    const anchor = [...list.children].find(row => row.getBoundingClientRect().bottom > main.getBoundingClientRect().top);
    const top = anchor?.getBoundingClientRect().top;
    const focused = document.activeElement.closest(".entry");
    entries = next;
    render();
    const match = [...list.children].find(row => row.dataset.id === anchor?.dataset.id);
    if (match && main.scrollTop > 0) main.scrollTop += match.getBoundingClientRect().top - top;
    if (focused) [...list.children].find(row => row.dataset.id === focused.dataset.id)?.focus({ preventScroll: true });
    showError();
  } catch { showError("Could not load transcriptions. Reopen this window to try again."); }
}

search.oninput = () => {
  render();
  document.querySelector("main").scrollTop = 0;
};
document.getElementById("clear").onclick = async () => {
  try {
    entries = await window.app.historyClear();
    if (!entries.length) expanded.clear();
    render();
    showError();
  } catch { showError("Could not delete transcriptions. They have been kept."); }
};

window.app.onHistoryChanged(reload);
reload();
