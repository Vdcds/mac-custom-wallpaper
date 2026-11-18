import AppKit

// Sleep, a lock, or leaving the console arms one cycle. Unlock/wake alone
// cannot arm another cycle after the pending one has been consumed.
struct WakeGate {
    enum Event { case sleep, screenSleep, wake, screenWake, lock, unlock, inactive, active }
    private(set) var pending = false
    private(set) var sleeping = false
    private(set) var displayAsleep = false
    private(set) var locked = false
    private(set) var inactive = false
    private var notBefore = Date.distantPast

    mutating func accept(_ event: Event, now: Date = Date()) {
        switch event {
        case .sleep: pending = true; sleeping = true
        case .screenSleep: pending = true; displayAsleep = true
        case .wake: sleeping = false; notBefore = now.addingTimeInterval(1.2)
        case .screenWake: displayAsleep = false; notBefore = now.addingTimeInterval(1.2)
        case .lock: pending = true; locked = true
        case .unlock:
            // Successful authentication proves the session is awake. Do not
            // remain stuck if a corresponding workspace wake event was missed.
            locked = false; sleeping = false; displayAsleep = false; inactive = false
            notBefore = now.addingTimeInterval(0.7)
        case .inactive: pending = true; inactive = true
        case .active: inactive = false; notBefore = now.addingTimeInterval(0.7)
        }
    }
    mutating func consume(now: Date = Date(), sessionAvailable: Bool) -> Bool {
        guard pending, !sleeping, !displayAsleep, !locked, !inactive,
              sessionAvailable, now >= notBefore else { return false }
        pending = false
        return true
    }
    mutating func cancel() { pending = false }
}

@MainActor
final class WakeMonitor {
    var gate = WakeGate()
    var onReplay: (() -> Void)?
    var onSuspend: (() -> Void)?
    var onEvent: ((String) -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var observedLockedSession = false

    init() {
        let center = NSWorkspace.shared.notificationCenter
        let workspace: [(Notification.Name, WakeGate.Event)] = [
            (NSWorkspace.willSleepNotification, .sleep),
            (NSWorkspace.didWakeNotification, .wake),
            (NSWorkspace.screensDidSleepNotification, .screenSleep),
            (NSWorkspace.screensDidWakeNotification, .screenWake),
            (NSWorkspace.sessionDidResignActiveNotification, .inactive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .active)
        ]
        for (name, event) in workspace { observe(center, name, event) }
        let distributed = DistributedNotificationCenter.default()
        // loginwindow notifications supplement public workspace notifications.
        // The session dictionary is also checked immediately before any replay.
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), .lock)
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), .unlock)
        if Self.sessionSnapshot?.locked == true { receive(.lock, name: "initial locked session") }
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ event: WakeGate.Event) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.receive(event, name: name.rawValue) }
        }
        observers.append((center, token))
    }
    func receive(_ event: WakeGate.Event, name: String = "injected") {
        gate.accept(event)
        onEvent?(name)
        switch event {
        case .sleep, .screenSleep, .lock, .inactive: onSuspend?()
        default: break
        }
        if gate.pending && timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }
    private struct SessionSnapshot {
        let onConsole: Bool
        let locked: Bool
        var available: Bool { onConsole && !locked }
    }
    private static var sessionSnapshot: SessionSnapshot? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool else { return nil }
        return SessionSnapshot(onConsole: onConsole, locked: (session["CGSSessionScreenIsLocked"] as? Bool) ?? false)
    }
    static var sessionAvailable: Bool { sessionSnapshot?.available == true }
    private func tick() {
        let snapshot = Self.sessionSnapshot
        if snapshot?.locked == true {
            observedLockedSession = true
            if !gate.locked {
                gate.accept(.lock)
                onSuspend?()
            }
        } else if snapshot?.available == true && observedLockedSession {
            // Recover a missed distributed unlock only after observing a real
            // locked→unlocked transition. An early unlocked snapshot must not
            // cancel a lock notification before loginwindow finishes locking.
            gate.accept(.unlock)
            observedLockedSession = false
            onEvent?("session dictionary unlocked")
        }
        if gate.consume(sessionAvailable: snapshot?.available == true) { onReplay?() }
        if !gate.pending {
            timer?.invalidate(); timer = nil
            observedLockedSession = false
        }
    }
    func cancelPending() {
        gate.cancel(); timer?.invalidate(); timer = nil
        observedLockedSession = false
    }
    func shutdown() {
        cancelPending()
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
    }

}
