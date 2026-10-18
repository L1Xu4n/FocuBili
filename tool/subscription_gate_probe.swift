import Foundation

/// Compile alongside SubscriptionRunGate.swift on macOS; UIKit is unnecessary.
@main enum SubscriptionGateProbe {
    static func main() {
        let gate = SubscriptionRunGate()
        precondition(gate.begin() == nil)
        gate.configure(enabled: true, generation: 11)
        let first = gate.begin()!
        precondition(gate.begin() == nil, "Concurrent native runs must be rejected")
        precondition(gate.permits(11) && !gate.permits(10))
        precondition(gate.configure(enabled: true, generation: 11) == nil)
        precondition(gate.run == first, "Idempotent configure must preserve the active run")
        precondition(gate.configure(enabled: true, generation: 12) == first)
        precondition(!gate.permits(11) && !gate.finish(first))
        let second = gate.begin()!
        precondition(gate.configure(enabled: false, generation: 13) == second)
        precondition(!gate.permits(12) && gate.begin() == nil)
        precondition(!gate.finish(second), "Late completion after cancellation must be rejected")
        gate.configure(enabled: true, generation: 14)
        let third = gate.begin()!
        precondition(gate.finish(third))
        precondition(!gate.finish(third), "Expiration/completion must own a task only once")
        precondition(!gate.permits(14))
        let fourth = gate.begin()!
        precondition(!gate.permits(14, runToken: third), "An older engine must not notify during a newer run")
        precondition(gate.permits(14, runToken: fourth))
        precondition(gate.finish(fourth))
        let delivery = SubscriptionNotificationGate()
        precondition(SubscriptionNotificationGate.allows(true))
        let denied: [Any?] = [false, nil, "true", 1, NSNumber(value: 1), NSNull()]
        for reply in denied {
            precondition(!SubscriptionNotificationGate.allows(reply), "Only a boolean true guard reply may deliver")
        }
        precondition(!delivery.begin(""))
        precondition(delivery.begin("first") && delivery.begin("second"))
        precondition(!delivery.begin("first"), "Duplicate preparation must be rejected")
        precondition(delivery.finish("first"), "Cancellation owns only its request")
        precondition(!delivery.contains("first") && delivery.contains("second"))
        precondition(!delivery.finish("first"), "Late positive guard reply must not revive a cancelled request")
        precondition(delivery.finish("second"))
        precondition(!delivery.finish("second"), "Delivery is one-shot")
        precondition(!delivery.contains("unknown") && !delivery.finish("unknown"))
        print("NATIVE_SUBSCRIPTION_GATE_PASSED")
    }
}
