import { describe, expect, it } from "vitest";
import {
  COMPACT_W,
  EXPANDED_W,
  NOTCH_H,
  NOTCH_W,
  PANEL_H,
  PANEL_W,
  VIEW_LAYOUTS,
  WAKE_STRIP_H,
  WAKE_STRIP_W,
  botGlowColor,
  botGlowOpacity,
  botPosition,
  chatPromptHeight,
  colorForProject,
  islandSize,
  washRGBA,
  type BotStateName,
  type IslandViewName,
} from "./layout";

describe("island geometry", () => {
  it("uses the documented sizes for each mode", () => {
    expect(islandSize("hidden", "overview")).toEqual({ w: NOTCH_W, h: 0 });
    expect(islandSize("compact", "overview")).toEqual({ w: COMPACT_W, h: NOTCH_H });
    expect(islandSize("expanded", "overview")).toEqual({
      w: EXPANDED_W,
      h: VIEW_LAYOUTS.overview.height,
    });
  });

  it("grows the chat prompt with the conversation, capped at 300", () => {
    expect(chatPromptHeight(0)).toBe(240);
    expect(chatPromptHeight(1)).toBe(280);
    expect(chatPromptHeight(2)).toBe(300);
    expect(chatPromptHeight(50)).toBe(300);
    expect(islandSize("expanded", "prompt", 4)).toEqual({ w: EXPANDED_W, h: 300 });
  });

  it("keeps the window panel larger than every island view", () => {
    for (const layout of Object.values(VIEW_LAYOUTS)) {
      expect(layout.height).toBeLessThanOrEqual(PANEL_H);
      expect(layout.botX).toBeLessThanOrEqual(PANEL_W);
    }
    expect(WAKE_STRIP_W).toBeGreaterThan(0);
    expect(WAKE_STRIP_H).toBeGreaterThan(0);
  });

  it("places Mochi at the documented spots", () => {
    expect(botPosition("hidden", "overview", 0)).toEqual({
      cx: 46,
      cy: 16,
      diameter: 6,
      opacity: 0,
    });
    expect(botPosition("compact", "overview", NOTCH_H)).toEqual({
      cx: 40,
      cy: 16,
      diameter: 20,
      opacity: 1,
    });

    const overview = botPosition("expanded", "overview", 160);
    expect(overview.cx).toBe(VIEW_LAYOUTS.overview.botX);
    expect(overview.diameter).toBe(VIEW_LAYOUTS.overview.botDiameter);
    // header (42) + half of the remaining card (84) centres the character.
    expect(overview.cy).toBe(42 + (160 - 42 - 84) / 2 + 84 / 2);
    expect(overview.opacity).toBe(1);
  });

  it("rides the upload progress bar and clips at both ends", () => {
    const start = botPosition("expanded", "uploading", 176, 0);
    const middle = botPosition("expanded", "uploading", 176, 0.5);
    const end = botPosition("expanded", "uploading", 176, 1);
    expect(start.cx).toBe(36);
    expect(middle.cx).toBe(299);
    expect(end.cx).toBe(562);
    expect(start.cy).toBe(VIEW_LAYOUTS.uploading.botY);
    expect(start.diameter).toBe(VIEW_LAYOUTS.uploading.botDiameter);
  });

  it("has a layout for every named view", () => {
    const views: IslandViewName[] = [
      "overview", "empty", "approval", "question", "error", "finished",
      "confused", "upload", "uploading", "choose", "mail", "prompt",
      "searching", "result", "note", "settings", "greeting",
    ];
    for (const view of views) {
      expect(VIEW_LAYOUTS[view]).toBeDefined();
      expect(islandSize("expanded", view).w).toBe(EXPANDED_W);
    }
  });
});

describe("bot glow", () => {
  it("maps every state and defaults to white", () => {
    const expected: Partial<Record<BotStateName, string>> = {
      working: "#3B9EFF",
      thinking: "#A78BFA",
      searching: "#6366F1",
      approval: "#F5A524",
      error: "#F4505E",
      finished: "#34D399",
      ratelimit: "#F59E0B",
    };
    for (const [state, colour] of Object.entries(expected)) {
      expect(botGlowColor(state as BotStateName)).toBe(colour);
    }
    expect(botGlowColor("idle")).toBe("#FFFFFF");
    expect(botGlowOpacity("idle")).toBe(0.15);
    expect(botGlowOpacity("sleeping")).toBe(0.15);
    expect(botGlowOpacity("dizzy")).toBe(0);
    expect(botGlowOpacity("working")).toBe(0.65);
  });
});

describe("project colours and card washes", () => {
  it("matches known projects, case and whitespace included", () => {
    expect(colorForProject("  KORUS ")).toBe("#FF5A4E");
    expect(colorForProject("Notch-Buddy")).toBe("#EC4899");
    expect(colorForProject("notchbuddy web")).toBe("#EC4899");
  });

  it("returns a stable fallback for unknown names", () => {
    const a = colorForProject("a project nobody configured");
    expect(a).toBe(colorForProject("a project nobody configured"));
    expect(a).toMatch(/^#[0-9A-F]{6}$/);
  });

  it("never leaks a wash when there is none", () => {
    expect(washRGBA(null)).toBe("rgba(0,0,0,0)");
    expect(washRGBA("red")).toContain("244,80,94");
    expect(washRGBA("soft")).toContain("255,255,255");
  });
});
