const SAMPLE_RATE = 16000;
const SPEECH_RMS = 0.02;
const SILENCE_RMS = 0.012;
const FINISH_TIMEOUT_MS = 8000;
const MIN_PANEL = 96;

const surface = document.getElementById("surface");
const finalEl = document.getElementById("final");
const partialEl = document.getElementById("partial");
const scrollEl = document.getElementById("scroll");
const messageEl = document.getElementById("message");
const bars = [...document.querySelectorAll(".bar")];

let socket = null;
let stream = null;
let audio = null;
let worklet = null;
let session = null;

let finalText = "";
let partialText = "";
let queue = [];
let startedAt = 0;
let stopping = false;
let heardSpeech = false;
let silenceStart = 0;
let finishTimer = null;
let panelHeight = 180;

/* ------------------------------------ ui ------------------------------------ */

function setPhase(phase, message = "") {
  surface.dataset.phase = phase;
  messageEl.textContent = message;
}

function renderTranscript() {
  finalEl.textContent = finalText;
  partialEl.textContent = partialText;
  surface.dataset.empty = String(!finalText && !partialText);
  scrollEl.scrollTop = scrollEl.scrollHeight;
}

function pushLevel(rms) {
  const level = Math.min(1, Math.pow(Math.max(0, rms) * 8, 0.75));
  for (let i = 0; i < bars.length - 1; i++) {
    bars[i].style.setProperty("--l", bars[i + 1].style.getPropertyValue("--l") || 0);
  }
  bars[bars.length - 1].style.setProperty("--l", level.toFixed(3));
}

function resetBars() {
  bars.forEach((bar) => bar.style.setProperty("--l", 0));
}

/* ---------------------------------- session --------------------------------- */

function buildConfig(cfg) {
  const message = {
    api_key: cfg.apiKey,
    model: cfg.model,
    audio_format: "s16le",
    sample_rate: SAMPLE_RATE,
    num_channels: 1,
    enable_endpoint_detection: true,
  };
  if (cfg.languageHints?.length) message.language_hints = cfg.languageHints;
  if (cfg.context?.trim()) message.context = cfg.context.trim();
  if (cfg.translateTo) message.translation = { type: "one_way", target_language: cfg.translateTo };
  return message;
}

const isSpecialToken = (text) => /^<[^>]+>$/.test(text);

function keepToken(token) {
  if (isSpecialToken(token.text)) return false;
  if (!session.translateTo) return true;
  return token.translation_status === "translation";
}

function handleMessage(event) {
  let message;
  try { message = JSON.parse(event.data); } catch { return; }

  if (message.error_code) {
    fail(message.error_message || `Soniox error ${message.error_code}`);
    return;
  }

  let pending = "";
  for (const token of message.tokens || []) {
    if (!keepToken(token)) continue;
    if (token.is_final) finalText += token.text;
    else pending += token.text;
  }
  partialText = pending;
  renderTranscript();

  if (message.finished) finish();
}

async function start(cfg) {
  session = cfg;
  finalText = "";
  partialText = "";
  queue = [];
  stopping = false;
  heardSpeech = false;
  silenceStart = 0;
  startedAt = performance.now();
  resetBars();
  renderTranscript();
  setPhase("connecting");

  try {
    socket = new WebSocket("wss://stt-rt.soniox.com/transcribe-websocket");
    socket.binaryType = "arraybuffer";
    socket.onmessage = handleMessage;
    socket.onerror = () => fail("Soniox unreachable");
    socket.onopen = () => {
      socket.send(JSON.stringify(buildConfig(cfg)));
      for (const chunk of queue) socket.send(chunk);
      queue = [];
      if (!stopping) setPhase("listening");
    };

    stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        channelCount: 1,
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
      },
    });

    audio = new AudioContext({ sampleRate: SAMPLE_RATE, latencyHint: "interactive" });
    await audio.audioWorklet.addModule("pcm-processor.js");
    worklet = new AudioWorkletNode(audio, "pcm-processor", { numberOfOutputs: 0 });
    worklet.port.onmessage = ({ data }) => onAudioChunk(data);
    audio.createMediaStreamSource(stream).connect(worklet);
  } catch (err) {
    fail(err.name === "NotAllowedError" ? "Microphone denied" : err.message);
  }
}

function onAudioChunk({ pcm, rms }) {
  pushLevel(rms);

  if (socket?.readyState === WebSocket.OPEN) socket.send(pcm);
  else if (!stopping) queue.push(pcm);

  if (!session?.silenceStopMs) return;
  if (rms > SPEECH_RMS) { heardSpeech = true; silenceStart = 0; return; }
  if (!heardSpeech || rms > SILENCE_RMS) return;
  const now = performance.now();
  if (!silenceStart) silenceStart = now;
  else if (now - silenceStart > session.silenceStopMs) { silenceStart = 0; window.app.autostop(); }
}

function stopCapture() {
  worklet?.port.close();
  worklet?.disconnect();
  audio?.close();
  stream?.getTracks().forEach((track) => track.stop());
  worklet = null;
  audio = null;
  stream = null;
}

function stop() {
  if (stopping) return;
  stopping = true;
  stopCapture();
  setPhase("transcribing");
  if (socket?.readyState === WebSocket.OPEN) {
    socket.send("");
    finishTimer = setTimeout(finish, FINISH_TIMEOUT_MS);
  } else {
    finish();
  }
}

function finish() {
  clearTimeout(finishTimer);
  const text = (finalText + partialText).replace(/\s+/g, " ").trim();
  const durationMs = Math.round(performance.now() - startedAt);
  teardown();
  window.app.result({ text, durationMs });
}

function fail(message) {
  clearTimeout(finishTimer);
  teardown();
  setPhase("error", message);
  window.app.error(message);
}

function cancel() {
  clearTimeout(finishTimer);
  teardown();
  setPhase("idle");
}

function teardown() {
  stopCapture();
  if (socket) {
    socket.onmessage = null;
    socket.onerror = null;
    socket.onopen = null;
    if (socket.readyState <= WebSocket.OPEN) socket.close();
    socket = null;
  }
  queue = [];
  stopping = true;
}

/* --------------------------------- surface ---------------------------------- */

document.getElementById("control").addEventListener("click", () => window.app.toggleTranscript());

const grip = document.getElementById("grip");
grip.addEventListener("pointerdown", (event) => {
  event.preventDefault();
  grip.setPointerCapture(event.pointerId);
  const originY = event.screenY;
  const originHeight = panelHeight;
  const grows = surface.dataset.position === "bottom" ? -1 : 1;

  const onMove = (move) => {
    panelHeight = Math.max(MIN_PANEL, originHeight + grows * (move.screenY - originY));
    window.app.resizeTranscript(panelHeight);
  };
  const onUp = () => {
    grip.removeEventListener("pointermove", onMove);
    grip.removeEventListener("pointerup", onUp);
    window.app.commitResize();
  };
  grip.addEventListener("pointermove", onMove);
  grip.addEventListener("pointerup", onUp);
});

window.app.onLayout(({ position, open, height }) => {
  surface.dataset.position = position;
  surface.dataset.open = String(open);
  panelHeight = height;
});

window.app.onStart((cfg) => {
  surface.dataset.position = cfg.position;
  surface.dataset.open = String(cfg.open);
  panelHeight = cfg.height;
  start(cfg);
});
window.app.onStop(stop);
window.app.onCancel(cancel);
