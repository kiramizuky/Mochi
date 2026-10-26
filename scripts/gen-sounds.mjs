#!/usr/bin/env node
// Generates the 28 short WAV cues used by the Windows island.
//
// The macOS app ships its own recordings in NotchBuddy/Resources/sounds/, but
// those are brand assets: they are not in this repository and LICENSE-ASSETS.md
// keeps them proprietary. The Windows build therefore uses original, fully
// synthesised cues so a clean checkout can build and ship with audio.
//
// Output is deterministic: same input, same bytes. Run from the repo root:
//
//   node scripts/gen-sounds.mjs            # write shared/sounds/*.wav
//   node scripts/gen-sounds.mjs --check    # fail if files are missing/stale
//
// The names must stay in sync with windows/src/core/sound-names.ts.

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const OUT_DIR = join(ROOT, "shared", "sounds");
const SAMPLE_RATE = 44_100;
const CHECK = process.argv.includes("--check");

/** @typedef {{ start?: number, dur?: number, freq: number, end?: number, gain?: number, wave?: "sine" | "triangle" | "square" | "saw", attack?: number, release?: number, harmonics?: number[] }} Tone */
/** @typedef {{ start?: number, dur?: number, gain?: number, cutoff?: number, decay?: number }} Noise */

const NOTES = {
  C4: 261.63, D4: 293.66, E4: 329.63, F4: 349.23, G4: 392.0, A4: 440.0, B4: 493.88,
  C5: 523.25, D5: 587.33, E5: 659.25, F5: 698.46, G5: 783.99, A5: 880.0, B5: 987.77,
  C6: 1046.5, D6: 1174.66, E6: 1318.51, G6: 1567.98,
};

function waveform(kind, phase, harmonics = []) {
  const p = phase % 1;
  let v;
  switch (kind) {
    case "square":
      v = p < 0.5 ? 1 : -1;
      break;
    case "triangle":
      v = 4 * Math.abs(p - 0.5) - 1;
      break;
    case "saw":
      v = 2 * p - 1;
      break;
    default:
      v = Math.sin(2 * Math.PI * p);
  }
  // A touch of odd harmonics keeps the tiny speakers from sounding sterile.
  for (let h = 0; h < harmonics.length; h++) {
    const n = h + 2;
    v += harmonics[h] * Math.sin(2 * Math.PI * p * n);
  }
  return v;
}

function envelope(t, dur, attack, release) {
  if (t < attack) return t / Math.max(attack, 1e-4);
  const left = dur - t;
  if (left < release) return Math.max(0, left / Math.max(release, 1e-4));
  return 1;
}

function addTone(out, tone) {
  const {
    start = 0,
    dur = 0.2,
    freq,
    end,
    gain = 0.28,
    wave = "sine",
    attack = 0.006,
    release = Math.min(0.12, dur * 0.6),
    harmonics = [],
  } = tone;
  const from = Math.max(0, Math.floor(start * SAMPLE_RATE));
  const len = Math.min(out.length - from, Math.floor(dur * SAMPLE_RATE));
  const target = end ?? freq;
  let phase = 0;
  for (let i = 0; i < len; i++) {
    const t = i / SAMPLE_RATE;
    // Exponential glide sounds musical; linear sounds like a slide whistle.
    const f = freq * Math.pow(target / freq, t / dur);
    phase += f / SAMPLE_RATE;
    const env = envelope(t, dur, attack, release);
    out[from + i] += gain * env * waveform(wave, phase, harmonics);
  }
}

function addNoise(out, noise) {
  const { start = 0, dur = 0.1, gain = 0.15, cutoff = 0.45, decay = 4 } = noise;
  const from = Math.max(0, Math.floor(start * SAMPLE_RATE));
  const len = Math.min(out.length - from, Math.floor(dur * SAMPLE_RATE));
  // Deterministic xorshift, so the committed WAVs never change across machines.
  let seed = 0x9e3779b9;
  let filtered = 0;
  for (let i = 0; i < len; i++) {
    seed ^= seed << 13;
    seed ^= seed >>> 17;
    seed ^= seed << 5;
    const white = ((seed >>> 0) / 0xffffffff) * 2 - 1;
    filtered += cutoff * (white - filtered);
    const t = i / SAMPLE_RATE;
    const env = Math.exp(-decay * t) * Math.min(1, t / 0.002);
    out[from + i] += gain * env * filtered;
  }
}

function render(seconds, parts) {
  const out = new Float32Array(Math.ceil(seconds * SAMPLE_RATE));
  for (const part of parts) {
    if ("freq" in part) addTone(out, part);
    else addNoise(out, part);
  }
  return out;
}

/** @type {Record<string, {seconds: number, parts: (Tone|Noise)[]}>} */
const SOUNDS = {
  peek: {
    seconds: 0.14,
    parts: [
      { freq: NOTES.A5, end: NOTES.E6, dur: 0.1, gain: 0.22, wave: "sine" },
      { start: 0.07, freq: NOTES.E6, dur: 0.06, gain: 0.12, wave: "triangle" },
    ],
  },
  open: {
    seconds: 0.3,
    parts: [
      { freq: NOTES.E5, dur: 0.14, gain: 0.22, wave: "triangle" },
      { start: 0.11, freq: NOTES.A5, dur: 0.18, gain: 0.22, wave: "triangle" },
    ],
  },
  close: {
    seconds: 0.28,
    parts: [
      { freq: NOTES.A5, dur: 0.12, gain: 0.2, wave: "triangle" },
      { start: 0.1, freq: NOTES.E5, dur: 0.17, gain: 0.18, wave: "triangle" },
    ],
  },
  hover: {
    seconds: 0.06,
    parts: [{ freq: NOTES.C6, dur: 0.05, gain: 0.12, wave: "sine", release: 0.04 }],
  },
  blip: {
    seconds: 0.1,
    parts: [{ freq: NOTES.B5, dur: 0.08, gain: 0.18, wave: "square", harmonics: [0.12] }],
  },
  slap: {
    seconds: 0.2,
    parts: [
      { dur: 0.16, gain: 0.3, cutoff: 0.25, decay: 18 },
      { freq: 120, end: 70, dur: 0.14, gain: 0.32, wave: "sine", release: 0.12 },
    ],
  },
  annoyed: {
    seconds: 0.4,
    parts: [
      { freq: 190, dur: 0.13, gain: 0.26, wave: "square", harmonics: [0.2] },
      { start: 0.17, freq: 165, dur: 0.16, gain: 0.24, wave: "square", harmonics: [0.2] },
    ],
  },
  dizzy: {
    seconds: 0.7,
    parts: [
      { freq: 420, end: 300, dur: 0.18, gain: 0.18, wave: "triangle" },
      { start: 0.18, freq: 300, end: 430, dur: 0.18, gain: 0.18, wave: "triangle" },
      { start: 0.36, freq: 420, end: 260, dur: 0.24, gain: 0.16, wave: "triangle" },
    ],
  },
  greet: {
    seconds: 0.55,
    parts: [
      { freq: NOTES.C5, dur: 0.13, gain: 0.2, wave: "triangle" },
      { start: 0.12, freq: NOTES.E5, dur: 0.13, gain: 0.2, wave: "triangle" },
      { start: 0.24, freq: NOTES.G5, dur: 0.24, gain: 0.2, wave: "triangle", harmonics: [0.1] },
    ],
  },
  work: {
    seconds: 0.5,
    parts: [
      { freq: NOTES.A4, dur: 0.16, gain: 0.14, wave: "sine" },
      { start: 0.22, freq: NOTES.A4, dur: 0.16, gain: 0.12, wave: "sine" },
    ],
  },
  finish: {
    seconds: 0.6,
    parts: [
      { freq: NOTES.C5, dur: 0.12, gain: 0.2, wave: "triangle" },
      { start: 0.1, freq: NOTES.E5, dur: 0.12, gain: 0.2, wave: "triangle" },
      { start: 0.2, freq: NOTES.G5, dur: 0.14, gain: 0.2, wave: "triangle" },
      { start: 0.31, freq: NOTES.C6, dur: 0.25, gain: 0.22, wave: "triangle", harmonics: [0.08] },
    ],
  },
  error: {
    seconds: 0.5,
    parts: [
      { freq: NOTES.E5, dur: 0.15, gain: 0.22, wave: "triangle" },
      { start: 0.14, freq: NOTES.C5, dur: 0.15, gain: 0.22, wave: "triangle" },
      { start: 0.28, freq: NOTES.A4, dur: 0.2, gain: 0.2, wave: "triangle", release: 0.16 },
    ],
  },
  approval: {
    seconds: 0.45,
    parts: [
      { freq: NOTES.G5, dur: 0.13, gain: 0.2, wave: "sine" },
      { start: 0.16, freq: NOTES.C6, dur: 0.22, gain: 0.22, wave: "sine" },
    ],
  },
  question: {
    seconds: 0.3,
    parts: [{ freq: NOTES.D5, end: NOTES.A5, dur: 0.25, gain: 0.2, wave: "triangle" }],
  },
  approve: {
    seconds: 0.35,
    parts: [
      { freq: NOTES.C6, dur: 0.1, gain: 0.18, wave: "sine" },
      { start: 0.08, freq: NOTES.E6, dur: 0.22, gain: 0.24, wave: "sine", harmonics: [0.15] },
    ],
  },
  gulp: {
    seconds: 0.3,
    parts: [{ freq: 360, end: 110, dur: 0.26, gain: 0.28, wave: "sine", release: 0.18 }],
  },
  tick: {
    seconds: 0.04,
    parts: [
      { dur: 0.03, gain: 0.18, cutoff: 0.7, decay: 40 },
      { freq: NOTES.E6, dur: 0.025, gain: 0.08, wave: "square" },
    ],
  },
  send: {
    seconds: 0.32,
    parts: [{ freq: 330, end: 900, dur: 0.28, gain: 0.16, wave: "triangle", attack: 0.03 }],
  },
  love: {
    seconds: 0.5,
    parts: [
      { freq: NOTES.E5, dur: 0.18, gain: 0.16, wave: "sine", attack: 0.03 },
      { start: 0.16, freq: NOTES.C6, dur: 0.28, gain: 0.18, wave: "sine", attack: 0.03 },
      { start: 0.16, freq: NOTES.E6, dur: 0.28, gain: 0.08, wave: "sine" },
    ],
  },
  pop: {
    seconds: 0.12,
    parts: [
      { dur: 0.05, gain: 0.2, cutoff: 0.6, decay: 30 },
      { freq: 520, end: 260, dur: 0.1, gain: 0.24, wave: "sine" },
    ],
  },
  proud: {
    seconds: 0.5,
    parts: [
      { freq: NOTES.F4, dur: 0.16, gain: 0.16, wave: "triangle" },
      { start: 0.13, freq: NOTES.A4, dur: 0.16, gain: 0.18, wave: "triangle" },
      { start: 0.26, freq: NOTES.C5, dur: 0.22, gain: 0.2, wave: "triangle" },
    ],
  },
  wink: {
    seconds: 0.16,
    parts: [{ freq: NOTES.G6, dur: 0.12, gain: 0.16, wave: "sine", release: 0.1 }],
  },
  yawn: {
    seconds: 0.8,
    parts: [{ freq: 260, end: 150, dur: 0.75, gain: 0.18, wave: "sine", attack: 0.12, release: 0.35 }],
  },
  attach: {
    seconds: 0.24,
    parts: [
      { dur: 0.035, gain: 0.18, cutoff: 0.8, decay: 50 },
      { start: 0.08, dur: 0.035, gain: 0.2, cutoff: 0.6, decay: 45 },
      { start: 0.1, freq: NOTES.A5, dur: 0.1, gain: 0.1, wave: "triangle" },
    ],
  },
  think: {
    seconds: 0.42,
    parts: [
      { freq: NOTES.A4, dur: 0.12, gain: 0.11, wave: "sine" },
      { start: 0.16, freq: NOTES.C5, dur: 0.12, gain: 0.11, wave: "sine" },
      { start: 0.32, freq: NOTES.A4, dur: 0.1, gain: 0.09, wave: "sine" },
    ],
  },
  search: {
    seconds: 0.5,
    parts: [
      { freq: 600, end: 1400, dur: 0.2, gain: 0.12, wave: "triangle", attack: 0.04 },
      { start: 0.2, freq: 1400, end: 700, dur: 0.25, gain: 0.1, wave: "triangle", release: 0.2 },
    ],
  },
  rate: {
    seconds: 0.36,
    parts: [
      { freq: NOTES.B5, dur: 0.05, gain: 0.12, wave: "square" },
      { start: 0.12, freq: NOTES.B5, dur: 0.05, gain: 0.13, wave: "square" },
      { start: 0.24, freq: NOTES.D6, dur: 0.08, gain: 0.14, wave: "square" },
    ],
  },
  sleep: {
    seconds: 0.7,
    parts: [{ freq: 300, end: 170, dur: 0.65, gain: 0.14, wave: "sine", attack: 0.1, release: 0.4 }],
  },
};

function encodeWav(samples) {
  const data = Buffer.alloc(samples.length * 2);
  for (let i = 0; i < samples.length; i++) {
    const clamped = Math.max(-1, Math.min(1, samples[i]));
    data.writeInt16LE(Math.round(clamped * 32767), i * 2);
  }
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + data.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20); // PCM
  header.writeUInt16LE(1, 22); // mono
  header.writeUInt32LE(SAMPLE_RATE, 24);
  header.writeUInt32LE(SAMPLE_RATE * 2, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(data.length, 40);
  return Buffer.concat([header, data]);
}

/** Tiny peak normaliser so every cue is audible without clipping. */
function normalise(samples, peak = 0.75) {
  let max = 0;
  for (const v of samples) max = Math.max(max, Math.abs(v));
  if (max === 0) return samples;
  const scale = peak / max;
  for (let i = 0; i < samples.length; i++) samples[i] *= scale;
  return samples;
}

const files = new Map();
for (const [name, spec] of Object.entries(SOUNDS)) {
  files.set(`${name}.wav`, encodeWav(normalise(render(spec.seconds, spec.parts))));
}

if (CHECK) {
  const problems = [];
  for (const [file, expected] of files) {
    const path = join(OUT_DIR, file);
    if (!existsSync(path)) {
      problems.push(`${file} is missing`);
      continue;
    }
    const actual = readFileSync(path);
    const hash = createHash("sha256").update(actual).digest("hex").slice(0, 12);
    const want = createHash("sha256").update(expected).digest("hex").slice(0, 12);
    if (hash !== want) problems.push(`${file} is stale (${hash} != ${want})`);
  }
  if (problems.length) {
    console.error("Sound assets are not up to date:");
    for (const problem of problems) console.error(`  - ${problem}`);
    console.error("Run `node scripts/gen-sounds.mjs` to regenerate them.");
    process.exit(1);
  }
  console.log(`${files.size} sound assets are up to date.`);
} else {
  mkdirSync(OUT_DIR, { recursive: true });
  for (const [file, bytes] of files) writeFileSync(join(OUT_DIR, file), bytes);
  console.log(`Wrote ${files.size} WAV files to ${OUT_DIR}`);
}
