import { defineConfig, type Plugin } from "vite";
import { existsSync, mkdirSync, readdirSync, copyFileSync, createReadStream } from "node:fs";
import { resolve, join, extname } from "node:path";
import { SOUND_NAMES } from "./src/core/sound-names";

// ───────────────────────────────────────────────────────────────────────────────
// THE one and only place the shared sound folder is declared.
// The 28 WAVs are original, generated cues committed in `shared/sounds/` (see
// `scripts/gen-sounds.mjs`). The macOS recordings are brand assets and are not
// part of this repository.
export const SOUNDS_DIR = resolve(__dirname, "../shared/sounds");
// ───────────────────────────────────────────────────────────────────────────────

const soundFile = (name: string) => join(SOUNDS_DIR, `${name}.wav`);

/** Names that `sound.ts` will fetch but that are not on disk. */
function missingSounds(): string[] {
  return SOUND_NAMES.filter((name) => !existsSync(soundFile(name)));
}

/**
 * Serves SOUNDS_DIR at /sounds/*.wav in dev, and copies it into dist/sounds on build.
 * Keeps the WAVs out of windows/ while still shipping them inside the installer.
 *
 * A production build fails when a cue is missing: the app would otherwise start
 * silently and nobody would notice until a release was installed.
 */
function sharedSounds(): Plugin {
  const prefix = "/sounds/";
  return {
    name: "mochi-shared-sounds",
    configureServer(server) {
      const missing = missingSounds();
      if (missing.length) {
        server.config.logger.warn(
          `[sounds] missing ${missing.length} cue(s) in ${SOUNDS_DIR}: ${missing.join(", ")}\n` +
            `         run \`node scripts/gen-sounds.mjs\` from the repo root`,
        );
      }
      server.middlewares.use((req, res, next) => {
        if (!req.url?.startsWith(prefix)) return next();
        const name = decodeURIComponent(req.url.slice(prefix.length).split("?")[0]);
        if (name.includes("/") || name.includes("\\") || extname(name) !== ".wav") return next();
        const file = join(SOUNDS_DIR, name);
        if (!existsSync(file)) return next();
        res.setHeader("Content-Type", "audio/wav");
        createReadStream(file).pipe(res);
      });
    },
    closeBundle() {
      const missing = missingSounds();
      if (missing.length) {
        this.error(
          `Missing ${missing.length} sound cue(s) in ${SOUNDS_DIR}: ${missing.join(", ")}. ` +
            `Run \`node scripts/gen-sounds.mjs\` from the repo root.`,
        );
      }

      const out = resolve(__dirname, "dist/sounds");
      mkdirSync(out, { recursive: true });
      for (const name of SOUND_NAMES) {
        copyFileSync(soundFile(name), join(out, `${name}.wav`));
      }

      const extras = readdirSync(SOUNDS_DIR).filter(
        (f) => extname(f) === ".wav" && !(SOUND_NAMES as readonly string[]).includes(f.slice(0, -4)),
      );
      if (extras.length) {
        this.warn(`sounds not used by the island: ${extras.join(", ")}`);
      }
    },
  };
}

export default defineConfig({
  plugins: [sharedSounds()],
  clearScreen: false,
  server: { port: 1420, strictPort: true, host: "127.0.0.1" },
  envPrefix: ["VITE_", "TAURI_ENV_"],
  build: {
    target: "chrome110",
    minify: "esbuild",
    sourcemap: false,
    emptyOutDir: true,
    rollupOptions: {
      input: {
        island: resolve(__dirname, "index.html"),
        settings: resolve(__dirname, "settings.html"),
      },
    },
  },
});
