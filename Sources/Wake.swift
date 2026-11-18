import AppKit

// A cycle starts only with sleep/display-sleep. Wake/unlock alone cannot replay.
// A late duplicate wake is harmless because consuming a cycle clears pending.
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
        case .lock: locked = true
        case .unlock: locked = false; notBefore = now.addingTimeInterval(0.7)
        case .inactive: inactive = true
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
    static var sessionAvailable: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        let onConsole = (session[kCGSessionOnConsoleKey as String] as? Bool) ?? false
        let locked = (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
        return onConsole && !locked
    }
    private func tick() {
        let available = Self.sessionAvailable
        if gate.consume(sessionAvailable: available) { onReplay?() }
        if !gate.pending { timer?.invalidate(); timer = nil }
    }
    func cancelPending() { gate.cancel(); timer?.invalidate(); timer = nil }
    func shutdown() {
        cancelPending()
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
    }

}
