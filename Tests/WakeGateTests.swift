import Foundation

@main
struct WakeGateTests {
    static func main() {
        var passed = 0
        func check(_ value: Bool, _ name: String) {
            guard value else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            passed += 1
            print("PASS: \(name)")
        }
        let start = Date(timeIntervalSince1970: 1000)
        var gate = WakeGate()
        gate.accept(.lock, now: start)
        check(!gate.consume(now: start.addingTimeInterval(10), sessionAvailable: false), "locked desktop does not replay")
        gate.accept(.unlock, now: start.addingTimeInterval(10))
        check(!gate.consume(now: start.addingTimeInterval(10.1), sessionAvailable: true), "unlock waits for the lock-screen transition")
        check(gate.consume(now: start.addingTimeInterval(11), sessionAvailable: true), "lock and successful unlock replay without any sleep")
        gate.accept(.unlock, now: start.addingTimeInterval(12))
        gate.accept(.active, now: start.addingTimeInterval(12))
        gate.accept(.screenWake, now: start.addingTimeInterval(12))
        check(!gate.consume(now: start.addingTimeInterval(15), sessionAvailable: true), "duplicate unlock, active, and screen-wake events do not replay")

        gate = WakeGate()
        gate.accept(.lock, now: start)
        check(!gate.consume(now: start.addingTimeInterval(60), sessionAvailable: false), "time and failed authentication cannot release a locked cycle")
        check(!gate.consume(now: start.addingTimeInterval(60), sessionAvailable: true), "console availability alone cannot override a lock notification")

        gate = WakeGate()
        gate.accept(.lock, now: start)
        gate.accept(.sleep, now: start)
        gate.accept(.screenSleep, now: start)
        gate.accept(.unlock, now: start.addingTimeInterval(10))
        check(gate.consume(now: start.addingTimeInterval(11), sessionAvailable: true), "successful unlock recovers when wake notifications were missed")
        gate.accept(.wake, now: start.addingTimeInterval(11))
        gate.accept(.screenWake, now: start.addingTimeInterval(11))
        check(!gate.consume(now: start.addingTimeInterval(15), sessionAvailable: true), "late wake notifications do not repeat the authenticated cycle")

        gate = WakeGate()
        gate.accept(.inactive, now: start)
        gate.accept(.active, now: start.addingTimeInterval(10))
        check(!gate.consume(now: start.addingTimeInterval(11), sessionAvailable: false), "session reactivation still requires an available console")
        check(gate.consume(now: start.addingTimeInterval(11), sessionAvailable: true), "returning to an inactive user session replays once")

        gate = WakeGate()
        gate.accept(.lock, now: start)
        gate.cancel()
        gate.accept(.unlock, now: start.addingTimeInterval(10))
        check(!gate.consume(now: start.addingTimeInterval(11), sessionAvailable: true), "stopping replays cancels the pending locked cycle")

        gate = WakeGate()
        gate.accept(.unlock, now: start)
        gate.accept(.active, now: start)
        gate.accept(.wake, now: start)
        check(!gate.consume(now: start.addingTimeInterval(10), sessionAvailable: true), "unpaired notifications during ordinary use cannot arm a replay")

        gate.accept(.lock, now: start.addingTimeInterval(20))
        gate.accept(.unlock, now: start.addingTimeInterval(21))
        check(gate.consume(now: start.addingTimeInterval(22), sessionAvailable: true), "a subsequent real lock-unlock cycle is not suppressed by a cooldown")
        print("\(passed) lifecycle checks passed")
    }
}
