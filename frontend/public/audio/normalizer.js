class Normalizer extends AudioWorkletProcessor {
  constructor() {
    super();
    this.enabled = false;
    this.volume = 1;
    this.energy = 0;
    this.gain = 1;
    this.port.onmessage = ({ data }) => {
      if (data.reset) {
        this.energy = 0;
        this.gain = 1;
      } else {
        this.enabled = data.enabled === true;
        this.volume = data.volume;
      }
    };
  }

  process(inputs, outputs) {
    const input = inputs[0];
    const output = outputs[0];
    if (!input.length || !output.length) return true;
    const frames = output[0].length;
    let energy = 0;
    let peak = 0;
    for (const channel of input)
      for (const sample of channel) {
        energy += sample * sample;
        peak = Math.max(peak, Math.abs(sample));
      }
    this.energy +=
      (energy / (frames * input.length) - this.energy) *
      (1 - Math.exp(-frames / (sampleRate * 1.5)));
    const rms = Math.sqrt(this.energy);
    const desired =
      this.enabled && rms > 0.001 * this.volume && this.volume > 0
        ? Math.min(2, Math.max(0.25, (0.125 * this.volume) / rms))
        : 1;
    this.gain +=
      (desired - this.gain) *
      (1 - Math.exp(-frames / (sampleRate * (desired < this.gain ? 0.25 : 3))));
    const gain = this.enabled
      ? Math.min(this.gain, peak > 0 ? (0.98 * this.volume) / peak : this.gain)
      : 1;
    output.forEach((channel, index) => {
      const source = input[index] ?? input[0];
      for (let frame = 0; frame < frames; frame++) channel[frame] = source[frame] * gain;
    });
    return true;
  }
}

registerProcessor('musica-normalizer', Normalizer);
