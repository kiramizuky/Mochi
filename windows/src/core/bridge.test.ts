import { describe, expect, it } from "vitest";
import { Bridge, IS_TAURI, onDragDrop, onEvent } from "./bridge";

describe("bridge outside Tauri", () => {
  it("detects a plain browser and turns commands into no-ops", async () => {
    expect(IS_TAURI).toBe(false);
    await expect(Bridge.boot()).resolves.toBeNull();
    await expect(Bridge.setPaused(true)).resolves.toBeNull();
    await expect(Bridge.openUrl("https://example.com")).resolves.toBeNull();
  });

  it("still rejects for the calls the UI must show an error for", async () => {
    await expect(Bridge.hooksPreview(true)).rejects.toThrow("not running inside Coucou");
    await expect(Bridge.hooksApply(true, "abc")).rejects.toThrow();
    await expect(Bridge.chatSend("hi", null)).rejects.toThrow();
    await expect(Bridge.ingestFile("C:\\tmp\\a.txt")).rejects.toThrow();
  });

  it("subscribes to nothing, but returns an unsubscribe function", async () => {
    const offEvent = await onEvent("hook", () => {});
    const offDrop = await onDragDrop(() => {});
    expect(typeof offEvent).toBe("function");
    expect(typeof offDrop).toBe("function");
    expect(() => offEvent()).not.toThrow();
    expect(() => offDrop()).not.toThrow();
  });
});
