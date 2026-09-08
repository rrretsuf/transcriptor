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

function renderSummary() {
  if (!entries.length) {
    summary.textContent = "Everything you dictate is kept on this Mac.";
    return;
  }
  const words = entries.reduce((sum, entry) => sum + (entry.words || 0), 0);
  const minutes = Math.round(entries.reduce((sum, entry) => sum + (entry.durationMs || 0), 0) / 60000);
  summary.innerHTML =
    `<b>${entries.length.toLocaleString()}</b> dictations · <b>${words.toLocaleString()}</b> words · <b>${minutes}</b> min spoken`;
}

function empty(title, note) {
  list.innerHTML = `<div class="empty"><b>${title}</b>${note}</div>`;
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
  shown.forEach((entry, index) => {
    const row = document.createElement("article");
    row.className = "entry reveal";
    row.style.setProperty("--i", Math.min(index, 12));
    row.setAttribute("aria-expanded", "false");
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

    row.onclick = (event) => {
      const action = event.target.dataset?.act;
      if (action === "copy") {
        window.app.historyCopy(entry.text);
        event.target.textContent = "Copied";
        setTimeout(() => { event.target.textContent = "Copy"; }, 1200);
        return;
      }
      if (action === "delete") {
        window.app.historyDelete(entry.id).then((next) => { entries = next; render(); });
        return;
      }
      row.setAttribute("aria-expanded", row.getAttribute("aria-expanded") === "false");
    };
    list.appendChild(row);
  });
}

async function reload() {
  entries = await window.app.historyList();
  render();
}

search.oninput = render;
document.getElementById("clear").onclick = async () => {
  entries = await window.app.historyClear();
  render();
};

window.app.onHistoryChanged(reload);
reload();
