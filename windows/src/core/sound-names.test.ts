import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { SOUND_NAMES } from "./sound-names";

const SOUNDS_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "../../../shared/sounds");

describe("sound cues", () => {
  it("has the 28 unique, lowercase names the island expects", () => {
    expect(SOUND_NAMES).toHaveLength(28);
    expect(new Set(SOUND_NAMES).size).toBe(SOUND_NAMES.length);
    for (const name of SOUND_NAMES) {
      expect(name).toMatch(/^[a-z]+$/);
    }
  });

  it("ships a valid mono 16-bit PCM WAV for every name", () => {
    for (const name of SOUND_NAMES) {
      const bytes = readFileSync(join(SOUNDS_DIR, `${name}.wav`));
      expect(bytes.subarray(0, 4).toString("ascii"), `${name} is not RIFF`).toBe("RIFF");
      expect(bytes.subarray(8, 12).toString("ascii"), `${name} is not WAVE`).toBe("WAVE");
      expect(bytes.readUInt16LE(20), `${name} is not PCM`).toBe(1);
      expect(bytes.readUInt16LE(22), `${name} is not mono`).toBe(1);
      expect(bytes.readUInt16LE(34), `${name} is not 16-bit`).toBe(16);
      expect(bytes.readUInt32LE(24), `${name} is not 44.1 kHz`).toBe(44_100);
      expect(bytes.readUInt32LE(40), `${name} has no samples`).toBeGreaterThan(0);
      const dataEnd = 44 + bytes.readUInt32LE(40);
      expect(bytes.length).toBe(dataEnd);
    }
  });

  it("has no stray WAV files that the build would warn about", () => {
    const onDisk = readdirSync(SOUNDS_DIR)
      .filter((f) => f.endsWith(".wav"))
      .map((f) => f.slice(0, -4))
      .sort();
    expect(onDisk).toEqual([...SOUND_NAMES].sort());
  });
});
