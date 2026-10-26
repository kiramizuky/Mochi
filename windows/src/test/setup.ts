// The island's state machine and the sound bridge use `window.setTimeout`.
// Vitest runs in Node, so give them a window object; fake timers then replace
// the global setTimeout and everything behaves as it does in WebView2.

if (typeof globalThis.window === "undefined") {
  (globalThis as unknown as { window: unknown }).window = globalThis;
}
