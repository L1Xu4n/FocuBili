import Foundation
import CoreFoundation

/// All accesses are serialized on the main queue by the native scheduler.
final class SubscriptionRunGate {
    private(set) var enabled: Bool
    private(set) var generation: Int
    private(set) var run: String?
    init(enabled: Bool = false, generation: Int = 0) {
        self.enabled = enabled; self.generation = generation
    }
    @discardableResult func configure(enabled: Bool, generation: Int) -> String? {
        let previous = run
        if !enabled || generation != self.generation { run = nil }
        self.enabled = enabled; self.generation = generation
        return previous != run ? previous : nil
    }
    func begin() -> String? {
        guard enabled, run == nil else { return nil }
        let token = UUID().uuidString; run = token; return token
    }
    func finish(_ token: String) -> Bool {
        guard run == token else { return false }; run = nil; return true
    }
    func permits(_ generation: Int, runToken: String? = nil) -> Bool {
        enabled && self.generation == generation && run != nil &&
            (runToken == nil || runToken == run)
    }
}

/// Foreground preparations are request-owned; headless cancellation is engine-owned.
/// The plugin serializes settings replies, guard replies and cancellation on main.
final class SubscriptionNotificationGate {
    private var requests = Set<String>()
    private(set) var workerCancelled = false
    func cancelWorker() { workerCancelled = true }
    static func allows(_ reply: Any?) -> Bool {
        guard let value = reply as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue
    }
    func begin(_ request: String) -> Bool {
        !request.isEmpty && requests.insert(request).inserted
    }
    func contains(_ request: String) -> Bool { requests.contains(request) }
    @discardableResult func finish(_ request: String) -> Bool {
        requests.remove(request) != nil
    }
}

/// Shared by UI and headless engines in this process, with main-queue access.
/// An epoch belongs to one pre-focus preparation/run; ending focus cannot revive it.
final class SubscriptionFocusGate {
    static let shared = SubscriptionFocusGate()
    private(set) var active = false
    private(set) var epoch = 0
    func update(active: Bool) {
        if active && !self.active { epoch += 1 }
        self.active = active
    }
    func capture() -> Int? { active ? nil : epoch }
    func permits(_ epoch: Int?) -> Bool {
        guard let epoch = epoch else { return false }
        return !active && self.epoch == epoch
    }
}
