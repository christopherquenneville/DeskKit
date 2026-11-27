import AppKit

/// DeskKit needs the pointer's moves only while it's over a Dock copy or an edge sensor. After a day
/// of use, a DeskKit process was once found being sent every move anywhere on screen (a few percent
/// of a core with a game's fast mouse), while a fresh process wasn't. This notices that state, logs
/// which window the moves are addressed to, and gets out of it: first by building DeskKit's windows
/// again, then, if the moves keep coming, by restarting DeskKit.
@MainActor
final class StrayMoveGuard {
    /// Builds the Dock copies, picker and menu bar icon again.
    var rebuildWindows: () -> Void = {}
    /// Whether something that legitimately follows the pointer everywhere is open (the picker).
    var isFollowingPointer: () -> Bool = { false }

    /// This many moves away from DeskKit's windows within `span` seconds is the stray state:
    /// a mouse moving for a couple of seconds, which DeskKit should never hear about.
    nonisolated static let limit = 150
    nonisolated static let span: TimeInterval = 3

    /// Counts moves in stretches of `span` seconds; true on the move that reaches `limit`.
    struct Counter {
        private var count = 0
        private var since = -TimeInterval.infinity

        mutating func add(at now: TimeInterval) -> Bool {
            if now - since > StrayMoveGuard.span {
                since = now
                count = 0
            }
            count += 1
            return count == StrayMoveGuard.limit
        }
    }

    private var monitor: Any?
    private var strays = Counter()
    private var rebuiltAt: TimeInterval?
    private let startedAt = ProcessInfo.processInfo.systemUptime

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.check(event)
            return event
        }
    }

    private func check(_ event: NSEvent) {
        // An open menu tracks the pointer everywhere, as does the picker.
        if RunLoop.current.currentMode == .eventTracking || isFollowingPointer() { return }
        let point = NSEvent.mouseLocation
        if NSApp.windows.contains(where: { $0.isVisible && $0.frame.insetBy(dx: -4, dy: -4).contains(point) }) { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard strays.add(at: now) else { return }

        let target = NSApp.window(withWindowNumber: event.windowNumber).map { "\(type(of: $0)) \(event.windowNumber)" } ?? "window \(event.windowNumber), not DeskKit's"
        let key = NSApp.keyWindow.map { "\(type(of: $0))" } ?? "none"
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let visible = NSApp.windows.filter(\.isVisible).map { "\(type(of: $0))" }.joined(separator: ", ")
        appLog.error("""
            Getting every mouse move (\(Self.limit, privacy: .public) away from DeskKit's windows in \(Int(Self.span), privacy: .public) s), \
            addressed to \(target, privacy: .public); key window: \(key, privacy: .public), active: \(NSApp.isActive, privacy: .public), \
            in front: \(front, privacy: .public), visible: \(visible, privacy: .public)
            """)
        if let rebuiltAt, now - rebuiltAt < 60 {
            // Building the windows again didn't stop them. A fresh process doesn't get them; restart
            // (but not over and over: a process that has just started leaves it at the log).
            guard now - startedAt > 600 else { return }
            appLog.error("Still getting every mouse move after building the windows again: restarting DeskKit")
            relaunch()
        } else {
            rebuiltAt = now
            appLog.info("Building DeskKit's windows again")
            rebuildWindows()
        }
    }
}
