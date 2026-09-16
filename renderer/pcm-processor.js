const CHUNK = 640; // 40 ms at 16 kHz

class PcmProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.buffer = new Int16Array(CHUNK);
    this.count = 0;
    this.energy = 0;
    this.port.onmessage = ({ data }) => {
      if (data !== "flush") return;
      if (this.count) {
        const pcm = this.buffer.slice(0, this.count);
        this.port.postMessage({ pcm: pcm.buffer, rms: Math.sqrt(this.energy / this.count) }, [pcm.buffer]);
        this.count = 0;
        this.energy = 0;
      }
      this.port.postMessage({ flushed: true });
    };
  }

  process(inputs) {
    const channel = inputs[0][0];
    if (!channel) return true;

    for (let i = 0; i < channel.length; i++) {
      const sample = Math.max(-1, Math.min(1, channel[i]));
      this.energy += sample * sample;
      this.buffer[this.count++] = sample < 0 ? sample * 0x8000 : sample * 0x7fff;

      if (this.count === CHUNK) {
        const pcm = this.buffer;
        this.port.postMessage(
          { pcm: pcm.buffer, rms: Math.sqrt(this.energy / CHUNK) },
          [pcm.buffer]
        );
        this.buffer = new Int16Array(CHUNK);
        this.count = 0;
        this.energy = 0;
      }
    }
    return true;
  }
}

registerProcessor("pcm-processor", PcmProcessor);
