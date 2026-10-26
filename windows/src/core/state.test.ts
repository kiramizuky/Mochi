import { describe, expect, it } from "vitest";
import { AppState, DEFAULT_SETTINGS, INTEGRATION_AGENTS } from "./state";

function fresh(): AppState {
  const state = new AppState();
  state.settings = {
    ...DEFAULT_SETTINGS,
    activeIntegrations: [...DEFAULT_SETTINGS.activeIntegrations],
  };
  return state;
}

describe("integration tasks", () => {
  it("always loads VS Code and only the integrations that are switched on", () => {
    const state = fresh();
    expect(state.tasks).toHaveLength(0);

    state.loadIntegrationTasks();
    expect(state.tasks.map((t) => t.id)).toEqual([
      "integration_claude",
      "integration_resend",
      "integration_n8n",
      "integration_vercel",
      "integration_github",
    ]);
    expect(state.focusId).toBe("integration_claude");

    state.settings.activeIntegrations = [];
    state.loadIntegrationTasks();
    expect(state.tasks.map((t) => t.id)).toEqual(["integration_claude"]);
  });

  it("keeps the declared order whatever order settings use", () => {
    const state = fresh();
    state.settings.activeIntegrations = [
      "integration_github",
      "integration_notion",
      "integration_resend",
      "integration_stripe",
    ];
    state.loadIntegrationTasks();
    const order = INTEGRATION_AGENTS.map((t) => t.id);
    const loaded = state.tasks.map((t) => t.id);
    expect(loaded).toEqual([...loaded].sort((a, b) => order.indexOf(a) - order.indexOf(b)));
  });

  it("refuses a fifth toggleable integration and allows four", () => {
    const state = fresh();
    state.loadIntegrationTasks();
    expect(state.settings.activeIntegrations).toHaveLength(4);

    state.toggleIntegration("integration_notion");
    expect(state.settings.activeIntegrations).toHaveLength(4);
    expect(state.tasks.some((t) => t.id === "integration_notion")).toBe(false);

    state.toggleIntegration("integration_vercel");
    expect(state.settings.activeIntegrations).not.toContain("integration_vercel");
    state.toggleIntegration("integration_notion");
    expect(state.settings.activeIntegrations).toEqual([
      "integration_resend",
      "integration_n8n",
      "integration_github",
      "integration_notion",
    ]);
    expect(state.tasks.some((t) => t.id === "integration_notion")).toBe(true);
  });

  it("cannot toggle VS Code, which is always loaded", () => {
    const state = fresh();
    state.loadIntegrationTasks();
    const before = [...state.settings.activeIntegrations];
    state.toggleIntegration("integration_claude");
    expect(state.settings.activeIntegrations).toEqual(before);
    expect(state.tasks.some((t) => t.id === "integration_claude")).toBe(true);

    state.setFocus("integration_github");
    state.toggleIntegration("integration_github");
    expect(state.focusId).toBe("integration_claude");
  });
});

describe("task bookkeeping", () => {
  it("clears a pill badge when the task is focused", () => {
    const state = fresh();
    state.loadIntegrationTasks();
    state.setPillBadge("integration_n8n", "approval");
    expect(state.tasks.find((t) => t.id === "integration_n8n")?.pillBadge).toBe("approval");

    state.setFocus("integration_n8n");
    expect(state.focusId).toBe("integration_n8n");
    expect(state.tasks.find((t) => t.id === "integration_n8n")?.pillBadge).toBeNull();
  });

  it("keeps only the last 20 steps and tracks the newest index", () => {
    const state = fresh();
    state.loadIntegrationTasks();
    for (let i = 0; i < 25; i++) state.appendStep("integration_claude", `step ${i}`);
    const task = state.tasks.find((t) => t.id === "integration_claude")!;
    expect(task.steps).toHaveLength(20);
    expect(task.steps[0]).toBe("step 5");
    expect(task.steps[19]).toBe("step 24");
    expect(task.stepIndex).toBe(19);
  });

  it("ignores updates for tasks that are not loaded", () => {
    const state = fresh();
    state.loadIntegrationTasks();
    state.updateTask("integration_stripe", "working");
    state.appendStep("integration_stripe", "nope");
    state.setPillBadge("integration_stripe", "error");
    expect(state.tasks.some((t) => t.id === "integration_stripe")).toBe(false);
  });

  it("derives the visible state from focus, then override", () => {
    const state = fresh();
    state.loadIntegrationTasks();
    state.updateTask("integration_claude", "working");
    expect(state.effectiveState).toBe("working");

    state.setFocus("integration_n8n");
    state.stateOverride = "sleeping";
    expect(state.effectiveState).toBe("sleeping");

    state.stateOverride = null;
    expect(state.effectiveState).toBe("idle");
    expect(state.defaultView()).toBe("overview");
  });

  it("shows the empty view when no integration task is loaded", () => {
    const state = fresh();
    expect(state.defaultView()).toBe("empty");
  });

  it("lists the other tasks for the pill row", () => {
    const state = fresh();
    state.loadIntegrationTasks();
    state.setFocus("integration_n8n");
    expect(state.otherTasks.some((t) => t.id === "integration_n8n")).toBe(false);
    expect(state.otherTasks).toHaveLength(4);
  });

  it("notifies subscribers only until they unsubscribe", () => {
    const state = fresh();
    let calls = 0;
    const off = state.subscribe(() => calls++);
    state.notify();
    expect(calls).toBe(1);
    off();
    state.notify();
    expect(calls).toBe(1);
  });
});

describe("AI provider defaults", () => {
  it("boots on Anthropic with a local endpoint ready to switch to", () => {
    expect(DEFAULT_SETTINGS.provider).toBe("anthropic");
    expect(DEFAULT_SETTINGS.model).toBe("claude-opus-5");
    expect(DEFAULT_SETTINGS.localEndpoint).toBe("http://127.0.0.1:11434/v1");
  });

  it("auto-detects the editor and terminal and asks for onboarding once", () => {
    expect(DEFAULT_SETTINGS.preferredEditor).toBe("auto");
    expect(DEFAULT_SETTINGS.preferredTerminal).toBe("auto");
    expect(DEFAULT_SETTINGS.onboarded).toBe(false);
  });
});
