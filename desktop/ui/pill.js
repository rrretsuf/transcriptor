const { listen } = window.__TAURI__.event;
const $ = (id) => document.getElementById(id);
const MAX_TEXT = 410;
const shape = [0.45, 0.75, 1, 0.75, 0.45];
const bars = [...$("bars").children];

function setText(final, partial) {
  $("final").textContent = final;
  $("partial").textContent = partial;
  const width = final || partial ? Math.ceil($("line").getBoundingClientRect().width) : 0;
  $("text").style.width = `${Math.min(width, MAX_TEXT)}px`;
  $("text").classList.toggle("clipped", width > MAX_TEXT);
}

function setLevel(rms) {
  const loud = Math.min(1, rms * 9);
  bars.forEach((bar, index) => { bar.style.height = `${5 + loud * 21 * shape[index]}px`; });
}

listen("pill", ({ payload }) => {
  const pill = $("pill");
  switch (payload.state) {
    case "recording":
      pill.className = "";
      setText("", "");
      setLevel(0);
      break;
    case "transcript":
      setText(payload.final, payload.partial);
      break;
    case "level":
      setLevel(payload.level);
      break;
    case "finishing":
      pill.className = "finishing";
      bars.forEach((bar) => { bar.style.height = ""; });
      break;
    case "fail":
      pill.className = "fail";
      setText(payload.message, "");
      break;
    case "idle":
    case "hidden":
      pill.classList.add("hidden");
      break;
  }
});
