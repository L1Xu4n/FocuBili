import Foundation
import AppKit
import WebKit

private func cookie(_ name: String, _ value: String, domain: String = ".bilibili.com", path: String = "/", expires: Date? = nil) -> HTTPCookie {
    var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path, .secure: "TRUE"]
    properties[.expires] = expires ?? Date().addingTimeInterval(3600)
    return HTTPCookie(properties: properties)!
}
private func wait<T>(_ start: (@escaping (T) -> Void) -> Void) -> T {
    var result: T?
    start { result = $0 }
    let end = Date().addingTimeInterval(15)
    while result == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    precondition(result != nil, "Cookie operation timed out")
    return result!
}
private final class MemoryCookies: BilibiliCookieContainer {
    var cookies: [HTTPCookie]
    var holdSet = false
    var release: (() -> Void)?
    var writes = 0
    init(_ cookies: [HTTPCookie]) { self.cookies = cookies }
    func read(_ completion: @escaping ([HTTPCookie]) -> Void) { DispatchQueue.main.async { completion(self.cookies) } }
    func delete(_ cookie: HTTPCookie, completion: @escaping () -> Void) {
        cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
        DispatchQueue.main.async(execute: completion)
    }
    func set(_ cookie: HTTPCookie, completion: @escaping () -> Void) {
        let apply = { self.writes += 1; self.cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }; self.cookies.append(cookie); completion() }
        if holdSet { release = apply } else { DispatchQueue.main.async(execute: apply) }
    }
}

@main enum BilibiliSessionProbe {
    static func main() {
        let path = "/x/player/wbi/playurl"
        let policy = BilibiliPlaybackCookiePolicy.self
        if let phase = CommandLine.arguments.dropFirst().first {
            precondition(ProcessInfo.processInfo.environment["CI"] == "true", "Persistent probe is CI-only")
            _ = NSApplication.shared
            let coordinator = BilibiliPlaybackSessionCoordinator(store: WebKitBilibiliCookieContainer())
            if phase == "persistent-write" {
                let before: BilibiliPlaybackSnapshot = wait { coordinator.read(path: path, completion: $0) }
                precondition(before.state == "anonymous" && before.header.isEmpty, "Persistent probe requires a clean CI container")
                let accepted: Bool = wait { coordinator.replace(header: "SESSDATA=synthetic-persistent; buvid3=synthetic-server", completion: $0) }
                precondition(accepted)
                let written: BilibiliPlaybackSnapshot = wait { coordinator.read(path: path, completion: $0) }
                precondition(written.header.contains("SESSDATA=synthetic-persistent"))
                RunLoop.main.run(until: Date().addingTimeInterval(2))
                print("APPLE_COOKIE_PERSISTENT_WRITE_PASSED")
            } else {
                precondition(phase == "persistent-read")
                let restored: BilibiliPlaybackSnapshot = wait { coordinator.read(path: path, completion: $0) }
                precondition(restored.state == "session" && restored.header.contains("SESSDATA=synthetic-persistent") && restored.header.contains("buvid3=synthetic-server"), "WK session did not persist across processes")
                let cleared: Bool = wait { coordinator.replace(header: nil, completion: $0) }
                precondition(cleared)
                print("APPLE_COOKIE_PERSISTENT_READ_PASSED")
            }
            return
        }
        let root = cookie("SESSDATA", "synthetic-one")
        precondition(policy.snapshot([root, cookie("outside", "synthetic", domain: ".evil.invalid")], path: path).header == "SESSDATA=synthetic-one")
        precondition(policy.snapshot([root, cookie("buvid3", "synthetic", domain: "www.bilibili.com")], path: path).header == "SESSDATA=synthetic-one", "Host-only cookie leaked across hosts")
        precondition(policy.snapshot([root, cookie("buvid3", "synthetic", path: "/x/player")], path: "/x/web-interface/nav").header == "SESSDATA=synthetic-one", "Path cookie leaked to nav")
        precondition(policy.snapshot([root, cookie("buvid3", "synthetic", path: "/x/play")], path: path).header == "SESSDATA=synthetic-one", "Cookie path boundary ignored")
        precondition(policy.snapshot([root, cookie("buvid3", "expired", expires: Date().addingTimeInterval(-1))], path: path).header == "SESSDATA=synthetic-one")
        precondition(policy.snapshot([root, cookie("SESSDATA", "synthetic-two", domain: "www.bilibili.com")], path: path).state == "conflict")
        precondition(policy.snapshot([cookie("bili_jct", "synthetic")], path: path).state == "partial")
        precondition(policy.snapshot([cookie("SESSDATA", "synthetic", domain: "passport.bilibili.com")], path: path).state == "partial")
        let intact = policy.snapshot([cookie("SESSDATA", "synthetic-one", domain: "api.bilibili.com"), cookie("DedeUserID", "synthetic-id")], path: path)
        precondition(intact.header == "SESSDATA=synthetic-one", "Identity fields were assembled across scopes")
        precondition(policy.imported("SESSDATA=one; SESSDATA=two") == nil)
        precondition(policy.imported("SESSDATA=one\r\nInjected: secret") == nil)
        precondition(policy.snapshot([root], path: "/untrusted").state == "unknown")
        let memory = MemoryCookies([root])
        let coordinator = BilibiliPlaybackSessionCoordinator(store: memory)
        let first: BilibiliPlaybackSnapshot = wait { coordinator.read(path: path, completion: $0) }
        let refreshed: BilibiliPlaybackSnapshot = wait { coordinator.merge(generation: first.generation, path: "/x/web-interface/nav", headers: [
            "bili_ticket=synthetic-issued; Domain=.bilibili.com; Path=/; Secure; HttpOnly",
            "SESSDATA=synthetic-unwanted; Domain=.bilibili.com; Path=/; Secure",
            "buvid4=synthetic-unwanted; Domain=.evil.invalid; Path=/; Secure"
        ], completion: $0) }
        precondition(refreshed.header.contains("bili_ticket=synthetic-issued") && refreshed.header.contains("SESSDATA=synthetic-one"))
        precondition(!refreshed.header.contains("synthetic-unwanted"), "Unapproved response cookie applied")
        let deleted: BilibiliPlaybackSnapshot = wait { coordinator.merge(generation: first.generation, path: path, headers: ["bili_ticket=; Domain=.bilibili.com; Path=/; Max-Age=0; Secure"], completion: $0) }
        precondition(!deleted.header.contains("bili_ticket="), "Expired response cookie not removed")
        memory.cookies = [cookie("SESSDATA", "synthetic-external")]
        let valid: Bool = wait { coordinator.validate(generation: first.generation, path: path, completion: $0) }
        precondition(!valid, "External WK change did not invalidate old request")
        let writes = memory.writes
        let stale: BilibiliPlaybackSnapshot = wait { coordinator.merge(generation: first.generation, path: path, headers: ["buvid3=synthetic-stale; Domain=.bilibili.com; Path=/; Secure"], completion: $0) }
        precondition(!stale.usable && memory.writes == writes, "Stale response wrote cookies")
        memory.holdSet = true
        var writeDone = false, readDone = false
        coordinator.replace(header: "SESSDATA=synthetic-replaced") { writeDone = $0 }
        coordinator.read(path: path) { snapshot in readDone = true; precondition(snapshot.header == "SESSDATA=synthetic-replaced") }
        let end = Date().addingTimeInterval(5)
        while memory.release == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(memory.release != nil && !readDone && !writeDone, "Read observed an incomplete write")
        memory.release!()
        while !readDone && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(readDone && writeDone)
        let beforeInvalid = memory.cookies.map { $0.value }
        let invalid: Bool = wait { coordinator.replace(header: "invalid-header", completion: $0) }
        precondition(!invalid && memory.cookies.map { $0.value } == beforeInvalid, "Invalid import cleared a valid session")
        print("APPLE_PLAYBACK_SESSION_POLICY_PASSED")
    }
}
