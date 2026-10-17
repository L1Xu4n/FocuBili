import Foundation

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
