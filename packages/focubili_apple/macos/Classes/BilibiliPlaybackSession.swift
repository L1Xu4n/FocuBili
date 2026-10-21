import Foundation
import WebKit

// All cookie values stay in memory. Only state and generation may enter logs.
struct BilibiliPlaybackSnapshot {
    let state: String
    let header: String
    let identity: [String: String]
    var generation: Int = 0
    var usable: Bool { state == "session" || state == "anonymous" }
    var payload: [String: Any] {
        ["state": state, "header": usable ? header : "", "generation": generation]
    }
}

enum BilibiliPlaybackCookiePolicy {
    static let identityNames: Set<String> = ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5"]
    static let responseNames: Set<String> = ["buvid3", "buvid4", "buvid_fp", "b_nut", "bili_ticket", "bili_ticket_expires"]
    static let paths: Set<String> = ["/x/web-interface/nav", "/x/web-interface/wbi/view", "/x/player/pagelist", "/x/player/playurl", "/x/player/wbi/playurl", "/pugv/player/web/playurl"]

    static func owned(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domain == "bilibili.com" || domain.hasSuffix(".bilibili.com")
    }

    static func domainMatches(_ cookie: HTTPCookie, host: String) -> Bool {
        let domain = cookie.domain.lowercased()
        if domain.hasPrefix(".") {
            let suffix = String(domain.dropFirst())
            return host == suffix || host.hasSuffix("." + suffix)
        }
        return host == domain
    }

    static func pathMatches(_ cookie: HTTPCookie, path: String) -> Bool {
        let prefix = cookie.path.isEmpty ? "/" : cookie.path
        return path == prefix || (path.hasPrefix(prefix) && (prefix.hasSuffix("/") || path.dropFirst(prefix.count).hasPrefix("/")))
    }

    static func valid(_ cookie: HTTPCookie, now: Date) -> Bool {
        owned(cookie) && (cookie.expiresDate.map { $0 > now } ?? true) &&
            !cookie.name.isEmpty && !cookie.value.isEmpty &&
            cookie.name.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil &&
            !cookie.value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    static func snapshot(_ cookies: [HTTPCookie], path: String, now: Date = Date()) -> BilibiliPlaybackSnapshot {
        guard paths.contains(path) else { return .init(state: "unknown", header: "", identity: [:]) }
        let valid = cookies.filter { Self.valid($0, now: now) }
        let identities = valid.filter { identityNames.contains($0.name) }
        let signature = Dictionary(identities.map { ("\($0.domain)|\($0.path)|\($0.name)", $0.value) }, uniquingKeysWith: { first, _ in first })
        for name in identityNames {
            if Set(identities.filter { $0.name == name }.map { $0.value }).count > 1 {
                return .init(state: "conflict", header: "", identity: signature)
            }
        }
        let applicable = valid.filter { domainMatches($0, host: "api.bilibili.com") && pathMatches($0, path: path) }
        let groups = Dictionary(grouping: applicable.filter { identityNames.contains($0.name) }) { "\($0.domain)|\($0.path)" }
        // Select an intact scope; never fill its identity fields from other scopes.
        let selected = groups.keys.sorted {
            let left = groups[$0]!.first!, right = groups[$1]!.first!
            if left.path.count != right.path.count { return left.path.count > right.path.count }
            if left.domain.count != right.domain.count { return left.domain.count > right.domain.count }
            return $0 < $1
        }.first { groups[$0]!.contains { $0.name == "SESSDATA" } }
        if selected == nil && !identities.isEmpty {
            return .init(state: "partial", header: "", identity: signature)
        }
        var values: [String: String] = [:]
        let device = applicable.filter { !identityNames.contains($0.name) }.sorted {
            if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
            if $0.domain.count != $1.domain.count { return $0.domain.count > $1.domain.count }
            return $0.domain < $1.domain
        }
        for cookie in device where values[cookie.name] == nil { values[cookie.name] = cookie.value }
        if let selected = selected {
            for cookie in groups[selected]! { values[cookie.name] = cookie.value }
        }
        let header = values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "; ")
        return .init(state: selected == nil ? "anonymous" : "session", header: header, identity: signature)
    }

    static func imported(_ header: String, now: Date = Date()) -> [HTTPCookie]? {
        guard !header.isEmpty, header.utf8.count <= 65536, !header.contains("\n"), !header.contains("\r") else { return nil }
        var values: [String: String] = [:]
        for raw in header.split(separator: ";") {
            let pair = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            let name = pair[0].trimmingCharacters(in: .whitespaces), value = pair[1].trimmingCharacters(in: .whitespaces)
            guard name.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil,
                  !value.isEmpty, !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
                  values[name] == nil || values[name] == value else { return nil }
            values[name] = value
        }
        guard !values.isEmpty else { return nil }
        let result = values.compactMap { name, value in HTTPCookie(properties: [
            .domain: ".bilibili.com", .path: "/", .name: name, .value: value,
            .secure: "TRUE", .expires: now.addingTimeInterval(86400 * 180)
        ]) }
        return result.count == values.count ? result : nil
    }
}

protocol BilibiliCookieContainer {
    func read(_ completion: @escaping ([HTTPCookie]) -> Void)
    func set(_ cookie: HTTPCookie, completion: @escaping () -> Void)
    func delete(_ cookie: HTTPCookie, completion: @escaping () -> Void)
}

final class WebKitBilibiliCookieContainer: BilibiliCookieContainer {
    private let store: WKHTTPCookieStore
    init(_ store: WKHTTPCookieStore = WKWebsiteDataStore.default().httpCookieStore) { self.store = store }
    func read(_ completion: @escaping ([HTTPCookie]) -> Void) { store.getAllCookies(completion) }
    func set(_ cookie: HTTPCookie, completion: @escaping () -> Void) { store.setCookie(cookie, completionHandler: completion) }
    func delete(_ cookie: HTTPCookie, completion: @escaping () -> Void) { store.delete(cookie, completionHandler: completion) }
}

// One coordinator is shared by foreground/headless bridges. Reads wait until
// complete replace/clear operations finish. Revisions also observe external WK
// identity changes; they are not based only on app-level login notifications.
final class BilibiliPlaybackSessionCoordinator {
    private let store: BilibiliCookieContainer
    private var pending: [(@escaping () -> Void) -> Void] = []
    private var busy = false
    private var revision = 0
    private var identity: [String: String]?
    // Server-issued device cookies form a generation-bound in-memory jar.
    // WK has no compare-and-set API: never let an old response write into a
    // shared browser container that may have switched accounts asynchronously.
    private var responseCookies: [String: HTTPCookie] = [:]
    private var responseScopes: Set<String> = []
    private var responseBase: [String: HTTPCookie] = [:]
    private func scope(_ cookie: HTTPCookie) -> String { "\(cookie.domain.lowercased())|\(cookie.path)|\(cookie.name)" }
    private func clearResponses() { responseCookies.removeAll(); responseScopes.removeAll(); responseBase.removeAll() }
    private func sameCookie(_ first: HTTPCookie?, _ second: HTTPCookie?) -> Bool {
        if first == nil && second == nil { return true }
        guard let first = first, let second = second else { return false }
        return first.value == second.value && first.expiresDate == second.expiresDate && first.isSecure == second.isSecure && first.isHTTPOnly == second.isHTTPOnly
    }
    init(store: BilibiliCookieContainer) { self.store = store }

    private func enqueue(_ work: @escaping (@escaping () -> Void) -> Void) {
        DispatchQueue.main.async { self.pending.append(work); self.advance() }
    }
    private func advance() {
        guard !busy, !pending.isEmpty else { return }
        busy = true
        let work = pending.removeFirst()
        work { self.busy = false; self.advance() }
    }
    private func observe(_ cookies: [HTTPCookie], path: String) -> BilibiliPlaybackSnapshot {
        let observed = BilibiliPlaybackCookiePolicy.snapshot(cookies, path: path)
        if let previous = identity, previous != observed.identity { revision += 1; clearResponses() }
        identity = observed.identity
        for key in Array(responseScopes) {
            let current = cookies.first { scope($0) == key }
            let previous = responseBase[key]
            if current == nil, let expiration = previous?.expiresDate, expiration <= Date() {
                responseBase.removeValue(forKey: key)
            } else if !sameCookie(current, previous) {
                responseScopes.remove(key); responseCookies.removeValue(forKey: key); responseBase.removeValue(forKey: key)
            }
        }
        let merged = cookies.filter { !responseScopes.contains(scope($0)) } + Array(responseCookies.values)
        var snapshot = BilibiliPlaybackCookiePolicy.snapshot(merged, path: path)
        snapshot.generation = revision
        return snapshot
    }
    func read(path: String, completion: @escaping (BilibiliPlaybackSnapshot) -> Void) {
        enqueue { done in self.store.read { cookies in
            completion(self.observe(cookies, path: path)); done()
        } }
    }
    func validate(generation: Int, path: String, completion: @escaping (Bool) -> Void) {
        read(path: path) { snapshot in completion(snapshot.usable && snapshot.generation == generation) }
    }
    func replace(header: String?, completion: @escaping (Bool) -> Void) {
        let imported = header.flatMap { BilibiliPlaybackCookiePolicy.imported($0) }
        if header != nil && imported == nil { completion(false); return }
        enqueue { done in
            self.revision += 1; self.clearResponses()
            self.store.read { cookies in
                let deletes = DispatchGroup()
                for cookie in cookies where BilibiliPlaybackCookiePolicy.owned(cookie) {
                    deletes.enter(); self.store.delete(cookie) { deletes.leave() }
                }
                deletes.notify(queue: .main) {
                    let writes = DispatchGroup()
                    for cookie in imported ?? [] { writes.enter(); self.store.set(cookie) { writes.leave() } }
                    writes.notify(queue: .main) {
                        self.revision += 1; self.identity = nil
                        completion(true); done()
                    }
                }
            }
        }
    }
    func merge(generation: Int, path: String, headers: [String], completion: @escaping (BilibiliPlaybackSnapshot) -> Void) {
        enqueue { done in self.store.read { existing in
            let before = self.observe(existing, path: path)
            guard before.usable, before.generation == generation,
                  BilibiliPlaybackCookiePolicy.paths.contains(path), headers.count <= 32,
                  headers.reduce(0, { $0 + $1.utf8.count }) <= 65536,
                  let url = URL(string: "https://api.bilibili.com" + path) else {
                completion(.init(state: "changing", header: "", identity: [:], generation: self.revision)); done(); return
            }
            for raw in headers where !raw.contains("\r") && !raw.contains("\n") {
                for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": raw], for: url) {
                    guard BilibiliPlaybackCookiePolicy.responseNames.contains(cookie.name),
                          BilibiliPlaybackCookiePolicy.owned(cookie),
                          BilibiliPlaybackCookiePolicy.domainMatches(cookie, host: "api.bilibili.com"),
                          cookie.path.hasPrefix("/") else { continue }
                    let maxAge = (cookie.properties?[.maximumAge]).flatMap { Int(String(describing: $0)) }
                    let expired = (cookie.expiresDate.map { $0 <= Date() } ?? false) || (maxAge.map { $0 <= 0 } ?? false)
                    let key = self.scope(cookie)
                    self.responseBase[key] = existing.first { self.scope($0) == key }
                    if expired {
                        self.responseScopes.insert(key); self.responseCookies.removeValue(forKey: key)
                    } else if BilibiliPlaybackCookiePolicy.valid(cookie, now: Date()) {
                        self.responseScopes.insert(key); self.responseCookies[key] = cookie
                    }
                }
            }
            self.store.read { cookies in
                let after = self.observe(cookies, path: path)
                completion(after.generation == generation ? after : .init(state: "changing", header: "", identity: [:], generation: after.generation))
                done()
            }
        } }
    }
}
