import Foundation

/// Pumps the main run loop so the controller's scheduled timers fire while the
/// main actor still gets slots between slices to run the tasks their closures
/// enqueue.
@MainActor
enum TimerPump {
    /// Pumps for `seconds` total. For absence-of-activity assertions, which
    /// have no observable success state.
    static func pumpTimers(seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            pumpRunLoop(seconds: 0.05)
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Condition-driven pump: runs until `condition` holds or the timeout
    /// expires, so an assertion never hinges on a fixed delay outrunning
    /// timer-fire scheduling under load. Returns false on timeout.
    static func pumpTimers(
        timeout: TimeInterval = 2,
        until condition: @autoclosure () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            pumpRunLoop(seconds: 0.05)
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// Sync wrapper around the noasync-annotated `RunLoop.run(until:)`:
    /// `Task.sleep` does not spin the main run loop, so the poll timer never
    /// fires without this deliberate pump.
    private nonisolated static func pumpRunLoop(seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
