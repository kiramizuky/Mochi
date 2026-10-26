// The single list of sound cues. `scripts/gen-sounds.mjs` writes one WAV per
// name into shared/sounds/, and vite.config.ts fails the production build when
// any of them is missing. Keep this file free of DOM access: the Vite config
// imports it at build time.

export const SOUND_NAMES = [
  "peek", "open", "close", "hover", "blip", "slap", "annoyed", "dizzy", "greet",
  "work", "finish", "error", "approval", "question", "approve", "gulp", "tick",
  "send", "love", "pop", "proud", "wink", "yawn", "attach", "think", "search",
  "rate", "sleep",
] as const;

export type SoundName = (typeof SOUND_NAMES)[number];
