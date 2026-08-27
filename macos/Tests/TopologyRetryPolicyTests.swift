import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct TopologyRetryPolicyTests {
    static func main() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        check(TopologyTimingPolicy.healthGateDeadline(createdAt: now) ==
              now.addingTimeInterval(TopologyTimingPolicy.postCreationHealthGate),
              "health settling must be anchored to display creation, not delayed enumeration completion")

        var gate = TopologyAdvanceGate()
        check(gate.begin(), "first topology advance must enter")
        check(!gate.begin() && !gate.begin(), "reentrant advances must not enter concurrently")
        check(gate.end(), "multiple reentrant advances must coalesce into one deferred pass")
        check(gate.begin(), "deferred pass must be able to enter after the first pass exits")
        check(!gate.end(), "a clean pass must not schedule another run")

        var policy = TopologyRetryPolicy()

        let first = policy.deferRetry(for: 101, now: now)
        check(first == now.addingTimeInterval(TopologyRetryPolicy.firstRetryDelay),
              "first topology failure should receive only a short recovery delay")
        check(!policy.canAttempt(deviceId: 101,
                                 now: now.addingTimeInterval(TopologyRetryPolicy.firstRetryDelay - 1)),
              "device must not churn before its short retry deadline")
        check(policy.canAttempt(deviceId: 101, now: first),
              "device should retry as soon as the short delay expires")

        let second = policy.deferRetry(for: 101, now: first)
        check(second == first.addingTimeInterval(TopologyRetryPolicy.sustainedFailureDelay),
              "repeated failure must fall back to the long safety fuse")
        check(policy.canAttempt(deviceId: 202, now: now),
              "one device's retry fuse must not block another device")

        policy.reset(deviceId: 101)
        check(policy.canAttempt(deviceId: 101, now: now),
              "a new explicit topology intent resets stale retry state")
        print("Topology retry policy tests passed")
    }
}
