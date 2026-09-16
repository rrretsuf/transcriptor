const SAMPLE_RATE = 16000;
const SPEECH_RMS = 0.02;
const SILENCE_RMS = 0.012;
const FINISH_TIMEOUT_MS = 8000;
const MIN_PANEL = 96;
const CONNECT_TIMEOUT_MS = 10000;
const MAX_BUFFER_BYTES = SAMPLE_RATE * 2 * 15;

const traceLog = (label) => { if (window.__trace) console.log(`[trace] ${label} ${Math.round(performance.now())}`); };

const surface = document.getElementById("surface");
const finalEl = document.getElementById("final");
const partialEl = document.getElementById("partial");
const scrollEl = document.getElementById("scroll");
const textEl = document.getElementById("text");
const messageEl = document.getElementById("message");
const bars = [...document.querySelectorAll(".bar")];

let socket = null;
let stream = null;
let audio = null;
let source = null;
let worklet = null;
let session = null;
let audioContext = null;

let finalText = "";
let partialText = "";
let queue = [];
let startedAt = 0;
let stopping = false;
let heardSpeech = false;
let silenceStart = 0;
let finishTimer = null;
let panelHeight = 180;
let followTranscript = true;
let sessionGeneration = 0;
let connectTimer = null;
let captureStopped = false;
let capturedDuration = 0;
let lastContentHeight = 0;
let flushResolve = null;
let panelOpen = false;
let renderScheduled = false;
let scrollPadding = 0;

/* ------------------------------------ ui ------------------------------------ */

function setPhase(phase, message = "") {
  surface.dataset.phase = phase;
  messageEl.textContent = message;
}

// Collapsed the panel is invisible, so measuring and repainting it is pure waste.
function scheduleRender() {
  if (!panelOpen || renderScheduled) return;
  renderScheduled = true;
  requestAnimationFrame(() => {
    renderScheduled = false;
    renderTranscript();
  });
}

function measurePadding() {
  const style = getComputedStyle(scrollEl);
  scrollPadding = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom);
}

function renderTranscript() {
  if (finalEl.textContent !== finalText) finalEl.textContent = finalText;
  if (partialEl.textContent !== partialText) partialEl.textContent = partialText;
  surface.dataset.empty = String(!finalText && !partialText);
  reportContentHeight();
  if (followTranscript) scrollEl.scrollTop = scrollEl.scrollHeight;
}

function reportContentHeight() {
  const height = textEl.getBoundingClientRect().height + scrollPadding + 15;
  const next = Math.max(MIN_PANEL, Math.ceil(height));
  if (next !== lastContentHeight) {
    lastContentHeight = next;
    window.app.contentHeight(next);
  }
}

scrollEl.addEventListener("scroll", () => {
  followTranscript = scrollEl.scrollHeight - scrollEl.clientHeight - scrollEl.scrollTop < 24;
}, { passive: true });

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
  if (cfg.context?.trim()) message.context = { terms: cfg.context.split(/[,\n]+/).map(term => term.trim()).filter(Boolean) };
  if (cfg.translateTo) message.translation = { type: "one_way", target_language: cfg.translateTo };
  return message;
}

// One context lives as long as the renderer does; recreating it per session only
// re-pays the AudioContext latency for no benefit.
async function audioGraph() {
  if (audioContext && audioContext.state !== "closed") {
    await audioContext.resume().catch(() => {});
    return audioContext;
  }
  const context = new AudioContext({ sampleRate: SAMPLE_RATE, latencyHint: "interactive" });
  await context.audioWorklet.addModule("pcm-processor.js");
  audioContext = context;
  return context;
}

// Compiling the worklet costs ~50 ms the first time; pay it before the first hotkey press.
async function warmAudio() {
  try { await audioGraph(); } catch { /* the first dictation pays it instead */ }
}

// Opening the mic once spawns the audio helper process and warms the capture path,
// so the first hotkey press does not pay the spawn; the stream is dropped immediately.
async function warmMic() {
  try {
    const s = await navigator.mediaDevices.getUserMedia({
      audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    });
    s.getTracks().forEach((track) => track.stop());
  } catch { /* the first dictation asks for permission instead */ }
}

// A throwaway connection caches DNS + TLS so the next real one resumes instead of
// paying a full handshake (~1 s cold, ~0.3 s warm otherwise).
function warmSocket() {
  const ws = new WebSocket("wss://stt-rt.soniox.com/transcribe-websocket");
  const done = () => { clearTimeout(timer); if (ws.readyState <= WebSocket.OPEN) ws.close(); };
  const timer = setTimeout(done, 5000);
  ws.onopen = done;
  ws.onerror = done;
  ws.onclose = done;
}

function warmup() {
  warmAudio();
  warmMic();
  warmSocket();
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
  if (message.tokens) {
    partialText = pending;
    scheduleRender();
  }

  if (message.finished) finish();
}

async function start(cfg) {
  traceLog("start:called");
  const generation = ++sessionGeneration;
  followTranscript = true;
  session = cfg;
  finalText = "";
  partialText = "";
  queue = [];
  captureStopped = false;
  capturedDuration = 0;
  lastContentHeight = 0;
  stopping = false;
  heardSpeech = false;
  silenceStart = 0;
  startedAt = 0;
  resetBars();
  renderTranscript();
  setPhase("connecting");

  try {
    socket = new WebSocket("wss://stt-rt.soniox.com/transcribe-websocket");
    socket.binaryType = "arraybuffer";
    socket.onmessage = handleMessage;
    socket.onerror = () => fail("Soniox unreachable");
    socket.onclose = () => fail("Connection closed before transcription completed");
    connectTimer = setTimeout(() => fail("Connection timed out"), CONNECT_TIMEOUT_MS);
    socket.onopen = () => {
      traceLog("start:socket-open");
      clearTimeout(connectTimer);
      socket.send(JSON.stringify(buildConfig(cfg)));
      for (const chunk of queue) socket.send(chunk);
      queue = [];
      if (stopping && captureStopped) finalizeStream();
    };

    const [inputStream, context] = await Promise.all([
      navigator.mediaDevices.getUserMedia({
        audio: {
          channelCount: 1,
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        },
      }),
      audioGraph(),
    ]);
    traceLog("start:mic+audio-ready");

    if (generation !== sessionGeneration || stopping) {
      inputStream.getTracks().forEach((track) => track.stop());
      return;
    }
    stream = inputStream;
    stream.getTracks().forEach(track => { track.onended = () => fail("Microphone disconnected"); });
    audio = context;
    worklet = new AudioWorkletNode(context, "pcm-processor", { numberOfOutputs: 0 });
    worklet.port.onmessage = ({ data }) => {
      if (generation !== sessionGeneration) return;
      if (data.pcm) onAudioChunk(data);
      if (data.flushed) flushResolve?.();
    };
    source = context.createMediaStreamSource(stream);
    source.connect(worklet);
    await context.resume();
    if (generation !== sessionGeneration || stopping) return stopCapture();
    startedAt = performance.now();
    // Audio captured before the socket opens is queued, so waiting on it would only stall the UI.
    setPhase("listening");
    traceLog("start:listening");
  } catch (err) {
    if (generation !== sessionGeneration || stopping) return;
    fail(err.name === "NotAllowedError" ? "Microphone denied" : err.message);
  }
}

function onAudioChunk({ pcm, rms }) {
  pushLevel(rms);

  if (socket?.readyState === WebSocket.OPEN) {
    if (socket.bufferedAmount > MAX_BUFFER_BYTES) return fail("Connection is too slow");
    socket.send(pcm);
  } else if (socket?.readyState === WebSocket.CONNECTING) {
    if (queue.length * 1280 >= MAX_BUFFER_BYTES) return fail("Connection is too slow");
    queue.push(pcm);
  }

  if (stopping) return;

  if (!session?.silenceStopMs) return;
  if (rms > SPEECH_RMS) { heardSpeech = true; silenceStart = 0; return; }
  if (rms > SILENCE_RMS) { silenceStart = 0; return; }
  if (!heardSpeech) return;
  const now = performance.now();
  if (!silenceStart) silenceStart = now;
  else if (now - silenceStart > session.silenceStopMs) { silenceStart = 0; window.app.autostop(); }
}

function stopCapture() {
  source?.disconnect();
  worklet?.port.close();
  worklet?.disconnect();
  stream?.getTracks().forEach((track) => { track.onended = null; track.stop(); });
  // The context stays alive for the next session; only the capture is released.
  audioContext?.suspend().catch(() => {});
  source = null;
  worklet = null;
  audio = null;
  stream = null;
}

async function stop() {
  if (stopping) return;
  stopping = true;
  capturedDuration = startedAt ? Math.round(performance.now() - startedAt) : 0;
  setPhase("transcribing");
  const generation = sessionGeneration;
  stream?.getTracks().forEach(track => { track.onended = null; track.stop(); });
  if (worklet) {
    await new Promise(resolve => {
      const timer = setTimeout(resolve, 100);
      flushResolve = () => { clearTimeout(timer); resolve(); };
      worklet.port.postMessage("flush");
    });
  }
  if (generation !== sessionGeneration) return;
  flushResolve = null;
  stopCapture();
  captureStopped = true;
  if (socket?.readyState === WebSocket.OPEN) finalizeStream();
}

function finalizeStream() {
  if (finishTimer) return;
  socket.send("");
  finishTimer = setTimeout(() => fail("Final transcription timed out"), FINISH_TIMEOUT_MS);
}

function resultPayload() {
  return {
    id: session?.id,
    text: (finalText + partialText).replace(/\s+/g, " ").trim(),
    durationMs: stopping ? capturedDuration : startedAt ? Math.round(performance.now() - startedAt) : 0,
  };
}

function finish() {
  const result = resultPayload();
  teardown();
  setPhase("idle");
  window.app.result(result);
}

function fail(message) {
  const result = resultPayload();
  teardown();
  setPhase("error", message);
  messageEl.title = message;
  window.app.error({ ...result, message });
}

function cancel() {
  teardown();
  setPhase("idle");
}

function teardown() {
  sessionGeneration++;
  clearTimeout(finishTimer);
  clearTimeout(connectTimer);
  finishTimer = null;
  connectTimer = null;
  flushResolve?.();
  flushResolve = null;
  stopCapture();
  if (socket) {
    socket.onmessage = null;
    socket.onerror = null;
    socket.onopen = null;
    socket.onclose = null;
    if (socket.readyState <= WebSocket.OPEN) socket.close();
    socket = null;
  }
  queue = [];
  stopping = true;
  finalText = "";
  partialText = "";
  renderTranscript();
  // The TLS cache from this session goes stale; refresh it for the next one.
  setTimeout(warmSocket, 30000);
}

/* --------------------------------- surface ---------------------------------- */

document.getElementById("control").addEventListener("click", () => window.app.toggleTranscript());

const grip = document.getElementById("grip");
grip.addEventListener("pointerdown", (event) => {
  event.preventDefault();
  grip.setPointerCapture(event.pointerId);
  const originY = event.screenY;
  const originHeight = panelHeight;
  const grows = surface.dataset.position === "bottom" ? -1 : 2;

  const onMove = (move) => {
    panelHeight = Math.max(MIN_PANEL, originHeight + grows * (move.screenY - originY));
    window.app.resizeTranscript(panelHeight);
  };
  const onUp = () => {
    grip.removeEventListener("pointermove", onMove);
    grip.removeEventListener("pointerup", onUp);
    grip.removeEventListener("pointercancel", onUp);
    grip.removeEventListener("lostpointercapture", onUp);
    window.app.commitResize();
  };
  grip.addEventListener("pointermove", onMove);
  grip.addEventListener("pointerup", onUp);
  grip.addEventListener("pointercancel", onUp);
  grip.addEventListener("lostpointercapture", onUp);
});

window.app.onLayout(({ position, open, height }) => {
  surface.dataset.position = position;
  surface.dataset.open = String(open);
  panelHeight = height;
  panelOpen = open;
  measurePadding();
  warmAudio();
  if (open) renderTranscript();
});

window.app.onStart((cfg) => {
  surface.dataset.position = cfg.position;
  surface.dataset.open = String(cfg.open);
  panelOpen = cfg.open;
  // The main process sends the actual clamped height via onLayout.
  start(cfg);
});

measurePadding();
window.app.onStop(stop);
window.app.onCancel(cancel);
window.app.onPolishing(() => setPhase("polishing"));

// Warm once shortly after launch so the boot paint and the warmup do not compete.
setTimeout(warmup, 400);
