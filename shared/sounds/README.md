# Island sound cues

The 28 WAV files in this folder are the cues the Windows island plays. They are
original, procedurally synthesised audio written for this repository — **not**
the macOS recordings in `NotchBuddy/Resources/sounds/`, which stay proprietary
brand assets (see `LICENSE-ASSETS.md`).

The files are committed so that a clean checkout can build and ship with audio.
They are generated deterministically by:

```powershell
node scripts/gen-sounds.mjs           # regenerate every cue
node scripts/gen-sounds.mjs --check   # fail if a file is missing or stale
```

`windows/src/core/sound-names.ts` is the list of names; the generator, the Vite
build validation and the app all read from it. `windows/vite.config.ts` fails a
production build when any cue is missing.

## Format

- 44.1 kHz, mono, 16-bit PCM — decodable by WebView2's `decodeAudioData`.
- Short (40 ms to 800 ms), peak-normalised to −2.5 dBFS.
- Seeded synthesis only: no random timestamps, so the bytes are stable.

## License

These generated cues are dedicated to the public domain under
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/), on top of the
repository's MIT License for the generator that produces them. Reuse them in
your own app; give it your own name, icon and character.
