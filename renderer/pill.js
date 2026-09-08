const SAMPLE_RATE = 16000;
const BAR_COUNT = 11;
const SPEECH_RMS = 0.02;
const SILENCE_RMS = 0.012;
const FINISH_TIMEOUT_MS = 8000;

const shell = document.getElementById("shell");
const transcriptEl = document.getElementById("transcript");
const finalEl = document.getElementById("final");
const partialEl = document.getElementById("partial");
const hintEl = document.getElementById("hint");
const bars = [...document.querySelectorAll(".bar")];

let socket = null;
let stream = null;
let audio = null;
let worklet = null;
let session = null;

let finalText = "";
let partialText = "";
let queue = [];
let stopping = false;
let heardSpeech = false;
let silenceStart = 0;
let finishTimer = null;

/* ------------------------------------ ui ------------------------------------ */

function setPhase(phase, hint) {
  shell.dataset.phase = phase;
  if (hint !== undefined) hintEl.textContent = hint;
}

function renderTranscript() {
  finalEl.textContent = finalText;
  partialEl.textContent = partialText;
  transcriptEl.classList.toggle("visible", Boolean(finalText || partialText));
  transcriptEl.scrollTop = transcriptEl.scrollHeight;
}

function pushLevel(rms) {
  const level = Math.min(1, Math.pow(Math.max(0, rms) * 8, 0.75));
  for (let i = 0; i < BAR_COUNT - 1; i++) bars[i].style.height = bars[i + 1].style.height;
  bars[BAR_COUNT - 1].style.height = `${4 + level * 24}px`;
}

function resetBars() {
  bars.forEach((bar) => { bar.style.height = "4px"; });
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

function isSpecialToken(text) {
  return /^<[^>]+>$/.test(text);
}

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
  resetBars();
  renderTranscript();
  setPhase("connecting", "Connecting…");

  try {
    socket = new WebSocket("wss://stt-rt.soniox.com/transcribe-websocket");
    socket.binaryType = "arraybuffer";
    socket.onmessage = handleMessage;
    socket.onerror = () => fail("Could not reach Soniox.");
    socket.onopen = () => {
      socket.send(JSON.stringify(buildConfig(cfg)));
      for (const chunk of queue) socket.send(chunk);
      queue = [];
      if (!stopping) setPhase("listening", `Listening — ${cfg.hotkeyLabel} to finish`);
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
    fail(err.name === "NotAllowedError" ? "Microphone access denied." : err.message);
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
  else if (now - silenceStart > session.silenceStopMs) { silenceStart = 0; window.flow.autostop(); }
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
  setPhase("transcribing", "Transcribing…");
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
  teardown();
  window.flow.result(text);
}

function fail(message) {
  clearTimeout(finishTimer);
  teardown();
  setPhase("error", message);
  window.flow.error(message);
}

function cancel() {
  clearTimeout(finishTimer);
  teardown();
  setPhase("idle", "");
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

window.flow.onStart(start);
window.flow.onStop(stop);
window.flow.onCancel(cancel);
