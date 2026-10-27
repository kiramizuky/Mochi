import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { IslandStateMachine, type FsmState } from "./fsm";

function make() {
  const fsm = new IslandStateMachine();
  const transitions: Array<[FsmState, FsmState]> = [];
  fsm.onTransition = (from, to) => transitions.push([from, to]);
  return { fsm, transitions };
}

beforeEach(() => {
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
});

describe("IslandStateMachine", () => {
  it("peeks from hidden on hover and retracts after the compact delay", () => {
    const { fsm, transitions } = make();
    expect(fsm.state).toBe("hidden");

    fsm.mouseEntered();
    expect(fsm.state).toBe("petit");

    fsm.mouseLeft();
    vi.advanceTimersByTime(59_000);
    expect(fsm.state).toBe("petit");
    vi.advanceTimersByTime(1_000);
    expect(fsm.state).toBe("hidden");

    expect(transitions).toEqual([
      ["hidden", "petit"],
      ["petit", "hidden"],
    ]);
  });

  it("a click opens home and leaving collapses it after 15 s", () => {
    const { fsm } = make();
    fsm.mouseEntered();
    fsm.click();
    expect(fsm.state).toBe("home");

    fsm.mouseLeft();
    vi.advanceTimersByTime(14_999);
    expect(fsm.state).toBe("home");
    vi.advanceTimersByTime(1);
    expect(fsm.state).toBe("petit");
  });

  it("keeps an alert pinned open", () => {
    const { fsm } = make();
    fsm.pinned = true;
    fsm.forceHome();
    fsm.mouseLeft();
    vi.advanceTimersByTime(120_000);
    expect(fsm.state).toBe("home");
  });

  it("collapses the launch greeting quickly, slowly while hovered", () => {
    const auto = make();
    auto.fsm.launch();
    expect(auto.fsm.state).toBe("coucou");
    auto.fsm.greetComplete();
    vi.advanceTimersByTime(599);
    expect(auto.fsm.state).toBe("coucou");
    vi.advanceTimersByTime(1);
    expect(auto.fsm.state).toBe("petit");

    const hovered = make();
    hovered.fsm.launch();
    hovered.fsm.mouseEntered();
    vi.advanceTimersByTime(9_999);
    expect(hovered.fsm.state).toBe("coucou");
    vi.advanceTimersByTime(1);
    expect(hovered.fsm.state).toBe("petit");
  });

  it("leaving the greeting retracts to compact and cancels the hover timer", () => {
    const { fsm } = make();
    fsm.launch();
    fsm.mouseEntered();
    fsm.mouseLeft();
    expect(fsm.state).toBe("petit");
    vi.advanceTimersByTime(120_000);
    // The 10 s greeting timer must not drag it away from petit later on. This
    // mirrors the macOS FSM: an interrupted greeting leaves the compact island
    // up until the next hover/leave cycle schedules its own hide.
    expect(fsm.state).toBe("petit");
  });

  it("reveals a work event and hides again when it goes stale", () => {
    const { fsm } = make();
    fsm.reveal();
    expect(fsm.state).toBe("petit");
    vi.advanceTimersByTime(60_000);
    expect(fsm.state).toBe("hidden");

    // reveal() from anything but hidden is a no-op.
    fsm.forceHome();
    fsm.reveal();
    expect(fsm.state).toBe("home");
  });

  it("forcePetit and forceHidden cancel every pending timer", () => {
    const { fsm, transitions } = make();
    fsm.reveal();
    fsm.forcePetit();
    transitions.length = 0;
    vi.advanceTimersByTime(120_000);
    expect(fsm.state).toBe("petit");
    expect(transitions).toEqual([]);

    fsm.forceHome();
    fsm.mouseLeft();
    fsm.forceHidden();
    transitions.length = 0;
    vi.advanceTimersByTime(120_000);
    expect(fsm.state).toBe("hidden");
    expect(transitions).toEqual([]);
  });

  it("never announces a transition to the state it is already in", () => {
    const { fsm, transitions } = make();
    fsm.forceHidden();
    fsm.forceHidden();
    expect(transitions).toEqual([]);
  });

  it("stays in petit and never auto-hides when keepVisible is true", () => {
    const { fsm } = make();
    fsm.keepVisible = true;
    fsm.mouseEntered();
    expect(fsm.state).toBe("petit");

    fsm.mouseLeft();
    vi.advanceTimersByTime(300_000);
    expect(fsm.state).toBe("petit");
  });
});
