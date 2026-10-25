import Foundation

/// Pure 4-state FSM for island open/close logic.
/// No AppKit / AppState dependencies — communicates via `onTransition`.
@MainActor
final class IslandStateMachine {

    enum State: Equatable {
        case hidden   // island invisible (notch size)
        case peek     // hover from hidden: compact wN+64, Ø 18 at x = 19
        case petit    // compact island (notch + ears)
        case home     // expanded, overview
        case coucou   // expanded, greeting animation
    }

    private(set) var state: State = .hidden

    /// Fired on every transition: (from, to)
    var onTransition: ((State, State) -> Void)?

    /// Predikat opsional: apakah diperbolehkan collapse dari home ke petit?
    var canCollapseHome: (() -> Bool)?

    /// home → petit delay (seconds). Override for debug.
    var homeToPetitDelay: TimeInterval = 15
    /// petit → hidden delay (seconds). Override for debug.
    var petitToHiddenDelay: TimeInterval = 60
    /// peek → hidden delay when mouse leaves the notch (seconds).
    var peekToHiddenDelay: TimeInterval = 0.6
    /// peek → expanded delay when mouse stays on the notch (seconds).
    var peekToExpandedDelay: TimeInterval = 0.65
    /// coucou → petit delay after greeting animation ends (no hover). ~0.6s syncs with canvas collapse.
    var greetAutoCollapseDelay: TimeInterval = 0.6
    /// coucou → petit delay when mouse is hovering over the greeting.
    var greetHoverCollapseDelay: TimeInterval = 10

    private var petitHideWork: DispatchWorkItem?
    private var homeCollapseWork: DispatchWorkItem?
    private var greetCollapseWork: DispatchWorkItem?
    private var peekHideWork: DispatchWorkItem?
    private var peekExpandWork: DispatchWorkItem?

    // MARK: – Inputs

    /// App launched or debug "launch greeting"
    func launch() {
        cancelTimers()
        transition(to: .coucou)
    }

    /// Mouse entered the island notch area
    func mouseEntered() {
        switch state {
        case .hidden:
            cancelTimers()
            transition(to: .peek)
            schedulePeekExpand()
        case .peek:
            peekHideWork?.cancel()
            peekHideWork = nil
        case .petit:
            petitHideWork?.cancel()
            petitHideWork = nil
        case .home:
            homeCollapseWork?.cancel()
            homeCollapseWork = nil
        case .coucou:
            // Mouse hovering during greeting — cancel short auto-collapse, extend to hover delay
            scheduleGreetCollapse(delay: greetHoverCollapseDelay)
        }
    }

    /// Mouse left the island notch area
    func mouseLeft() {
        switch state {
        case .hidden:
            break
        case .peek:
            schedulePeekHide()
        case .petit:
            schedulePetitHide()
        case .home:
            scheduleHomeCollapse()
        case .coucou:
            // Interrupt greeting immediately → compact (overrides 10s auto-collapse)
            greetCollapseWork?.cancel(); greetCollapseWork = nil
            transition(to: .petit)
        }
    }

    /// Compact island clicked.
    /// Also accepts `.hidden` / `.peek`: after an alert the island can be on screen while the
    /// FSM never saw the mouse enter (it was already there), and the click must still open it.
    func click() {
        guard state == .peek || state == .petit || state == .hidden else { return }
        cancelTimers()
        transition(to: .home)
    }

    /// The app hid the island on its own (e.g. `AppState.syncMode()` when the last
    /// task ends). Mirror it without side effects, so the next hover peeks again
    /// instead of being swallowed by a FSM that still thinks the island is `.petit`.
    func hiddenExternally() {
        guard state == .petit || state == .peek else { return }
        cancelTimers()
        state = .hidden
    }

    /// The island was opened from outside (menu bar, hotkey, MCP, expand).
    /// Transition directly to .home so FSM is in sync and hover doesn't collapse it.
    func openedExternally() {
        cancelTimers()
        transition(to: .home)
    }

    /// The app folded the island itself (Escape, Settings, OK button, auto-close).
    /// Move to `.petit` right away so hover and click keep working.
    func collapse() {
        guard state == .home || state == .coucou || state == .peek else { return }
        cancelTimers()
        transition(to: .petit)
    }

    /// Greeting animation finished (called at T.end ≈ 4.60 s).
    /// Schedules auto-collapse. Does not override a longer hover timer already running.
    func greetComplete() {
        guard state == .coucou else { return }
        // If mouse entered before this fires (hover timer already running), don't override it
        if greetCollapseWork == nil {
            scheduleGreetCollapse(delay: greetAutoCollapseDelay)
        }
    }

    private func scheduleGreetCollapse(delay: TimeInterval) {
        greetCollapseWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.state == .coucou else { return }
            self.transition(to: .petit)
        }
        greetCollapseWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Non-alert work event: show compact from hidden (HookServer reveal)
    func reveal() {
        guard state == .hidden || state == .peek else { return }
        cancelTimers()
        transition(to: .petit)
        schedulePetitHide()
    }

    // MARK: – Timers

    private func schedulePetitHide() {
        petitHideWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.state == .petit else { return }
            self.transition(to: .hidden)
        }
        petitHideWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + petitToHiddenDelay, execute: item)
    }

    private func scheduleHomeCollapse() {
        homeCollapseWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.state == .home else { return }
            if let can = self.canCollapseHome, !can() {
                // Tunda collapse jika kondisi belum memungkinkan (misal AI sedang generate atau bicara)
                self.scheduleHomeCollapse()
                return
            }
            self.transition(to: .petit)
        }
        homeCollapseWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + homeToPetitDelay, execute: item)
    }

    /// Mouse left peek → retract to hidden after peekToHiddenDelay.
    private func schedulePeekHide() {
        peekHideWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.state == .peek else { return }
            self.transition(to: .hidden)
        }
        peekHideWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + peekToHiddenDelay, execute: item)
    }

    /// Mouse stayed on peek → expand to home after peekToExpandedDelay.
    private func schedulePeekExpand() {
        peekExpandWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.state == .peek else { return }
            self.transition(to: .home)
        }
        peekExpandWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + peekToExpandedDelay, execute: item)
    }

    func cancelTimers() {
        petitHideWork?.cancel();    petitHideWork = nil
        homeCollapseWork?.cancel(); homeCollapseWork = nil
        greetCollapseWork?.cancel(); greetCollapseWork = nil
        peekHideWork?.cancel();     peekHideWork = nil
        peekExpandWork?.cancel();   peekExpandWork = nil
    }

    private func transition(to new: State) {
        guard new != state else { return }
        let old = state
        state = new
        onTransition?(old, new)
    }

}
