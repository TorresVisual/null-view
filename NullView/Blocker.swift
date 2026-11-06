import ContentBlockerConverter
import FilterEngine
import NullViewCore
import SwiftUI
import WebKit

/// Content blocking (decisions.md "Content blocking"): AdGuard's converter turns list text into
/// Safari rules compiled to `WKContentRuleList`; the FilterEngine looks up cosmetic rules and
/// scriptlets per page, injected as a page-world user script with no message handler.
///
/// Rule: a failed download or compile never removes a working list. The compiled lists live in
/// `WKContentRuleListStore`, so a launch without network still blocks.
@MainActor
final class Blocker: ObservableObject {
    struct ListMeta: Codable {
        var updated: Date
        var safariRules: Int
        var sourceRules: Int
        var invalidRules: Int
        var discardedRules: Int
    }

    static let customID = "custom"
    private static let allowKey = "blockerAllowlist"
    private static let customKey = "blockerCustomRules"
    private static let filtersKey = "blockerFilters"
    /// A failing list (dead custom URL) would otherwise be retried on every return to the app.
    private static let retryAfter: TimeInterval = 600

    @Published private(set) var meta: [String: ListMeta] = [:]
    /// Last error per list id (in memory only; the previous good list stays active).
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var isUpdating = false
    @Published private(set) var allowlist: AllowList
    /// Which lists are on, plus the ones added by URL.
    @Published private(set) var config: FilterConfig

    private(set) var customRules: String
    private let ucc: WKUserContentController
    private var compiled: [String: WKContentRuleList] = [:]
    private var engine: WebExtension?
    private var attached = false
    private var currentURL: URL?
    private var lastUpdateAttempt = Date.distantPast
    private let dir: URL
    private let bundleJS: String
    /// Other user scripts (video detection). `removeAllUserScripts()` has no per-script variant,
    /// so they are re-added every time the blocker resets the scripts.
    private let persistentScripts: [WKUserScript]

    var hasError: Bool { !errors.isEmpty }
    private var ids: [String] { config.active.map(\.id) + [Self.customID] }

    init(userContentController: WKUserContentController, persistentScripts: [WKUserScript] = []) {
        ucc = userContentController
        self.persistentScripts = persistentScripts
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("blocker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dir = dir
        bundleJS = Bundle.main.url(forResource: "adblock-content", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let d = UserDefaults.standard
        allowlist = d.data(forKey: Self.allowKey).flatMap { try? JSONDecoder().decode(AllowList.self, from: $0) } ?? AllowList()
        customRules = d.string(forKey: Self.customKey) ?? ""
        config = d.data(forKey: Self.filtersKey).flatMap { try? JSONDecoder().decode(FilterConfig.self, from: $0) } ?? FilterConfig()
        meta = (try? JSONDecoder().decode([String: ListMeta].self, from: Data(contentsOf: dir.appendingPathComponent("meta.json")))) ?? [:]
        if bundleJS.isEmpty { errors["engine"] = "adblock-content.js missing from the app bundle" }
    }

    // MARK: Lifecycle

    /// Launch: load the compiled lists from the store (fast, offline), then refresh if stale.
    func start() async {
        for id in ids {
            if let l = await Self.lookUp(id) { compiled[id] = l }
        }
        await rebuildEngine()
        refreshAttachment()
        await refreshIfStale()
    }

    /// Launch and every return to the front: iOS keeps the app alive for days, so launch alone is not enough.
    func refreshIfStale() async {
        guard Date().timeIntervalSince(lastUpdateAttempt) > Self.retryAfter,
              config.active.contains(where: { Filters.isStale(meta[$0.id]?.updated) }) else { return }
        await update()
    }

    /// Downloads, converts and compiles every list. Failures are recorded per list.
    func update() async {
        guard !isUpdating else { return }
        isUpdating = true
        lastUpdateAttempt = Date()
        defer { isUpdating = false }
        await withTaskGroup(of: (String, String?).self) { group in
            for l in config.active {
                group.addTask { (l.id, await self.download(l)) }
            }
            for await (id, err) in group { errors[id] = err }
        }
        await rebuildEngine()
        refreshAttachment()
    }

    /// Saves and compiles the custom rules (their own list). Returns an error message or nil.
    func saveCustomRules(_ text: String) async -> String? {
        customRules = text
        UserDefaults.standard.set(text, forKey: Self.customKey)
        var err: String?
        do { try await install(id: Self.customID, text: text, allowEmpty: true) } catch { err = error.localizedDescription }
        errors[Self.customID] = err
        await rebuildEngine()
        refreshAttachment()
        return err
    }

    /// Appends one rule line (from the element picker) to the custom rules and applies it.
    func addElementRule(_ line: String) async -> String? {
        guard !Filters.lines(customRules).contains(line) else { return nil }
        let sep = customRules.isEmpty || customRules.hasSuffix("
") ? "" : "
"
        return await saveCustomRules(customRules + sep + line)
    }

    // MARK: Lists

    /// Turns a list on (downloads it now) or off (forgets its compiled rules).
    func setEnabled(_ id: String, _ on: Bool) async {
        guard !isUpdating, let l = config.all.first(where: { $0.id == id }) else { return }
        isUpdating = true
        defer { isUpdating = false }
        config.setEnabled(id, on)
        saveConfig()
        if on { errors[id] = await download(l) } else { await drop(id) }
        await rebuildEngine()
        refreshAttachment()
    }

    /// Adds a list by URL. A list that does not download and compile is not kept. Returns an error message or nil.
    func addList(name: String, url: String) async -> String? {
        guard !isUpdating else { return "Wait for the running update to finish" }
        isUpdating = true
        defer { isUpdating = false }
        var next = config
        guard let l = next.addCustom(name: name, urlText: url) else { return "Enter a new address starting with https://" }
        if let err = await download(l) {
            await drop(l.id)
            return err
        }
        config = next
        saveConfig()
        await rebuildEngine()
        refreshAttachment()
        return nil
    }

    func removeList(_ id: String) async {
        guard config.isCustom(id) else { return }
        config.removeCustom(id)
        saveConfig()
        await drop(id)
        await rebuildEngine()
        refreshAttachment()
    }

    private func drop(_ id: String) async {
        compiled[id] = nil
        await Self.remove(id)
        meta[id] = nil
        errors[id] = nil
        try? FileManager.default.removeItem(at: advancedURL(id))
        persistMeta()
    }

    private func saveConfig() {
        UserDefaults.standard.set(try? JSONEncoder().encode(config), forKey: Self.filtersKey)
    }

    private func persistMeta() {
        try? JSONEncoder().encode(meta).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
    }

    // MARK: Per-page attachment

    /// Called before each main-frame navigation. Allowlisted hosts get no rule lists and no scripts.
    func apply(for url: URL?) {
        currentURL = url
        let on = !allowlist.contains(url?.host)
        if on != attached {
            ucc.removeAllContentRuleLists()
            if on { compiled.values.forEach { ucc.add($0) } }
            attached = on
        }
        ucc.removeAllUserScripts()
        persistentScripts.forEach { ucc.addUserScript($0) }
        guard on, !bundleJS.isEmpty, let url, ["http", "https"].contains(url.scheme),
              let c = engine?.lookup(pageUrl: url, topUrl: nil) else { return }
        let cfg: [String: Any] = [
            "css": c.css, "extendedCss": c.extendedCss, "js": c.js,
            "scriptlets": c.scriptlets.map { ["name": $0.name, "args": $0.args] },
            "engineTimestamp": c.engineTimestamp,
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: cfg) else { return }
        let src = "window.__nvConfig = \(String(decoding: d, as: UTF8.self));\n" + bundleJS
        // Page world on purpose: scriptlets patch page APIs. No message handler (decisions.md).
        ucc.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    }

    /// Lists changed (start/update/custom): force a re-attach for the current page.
    private func refreshAttachment() {
        attached = !attached
        apply(for: currentURL)
    }

    func isBlocking(on url: URL?) -> Bool { !allowlist.contains(url?.host) }

    /// Allowlist or un-allowlist the page's site. The caller reloads.
    func toggleAllow(for url: URL?) {
        guard let host = url?.host else { return }
        allowlist.toggle(host)
        saveAllowlist()
        apply(for: url)
    }

    func addAllowed(_ host: String) { allowlist.add(host); saveAllowlist(); apply(for: currentURL) }
    func removeAllowed(_ host: String) { allowlist.remove(host); saveAllowlist(); apply(for: currentURL) }

    private func saveAllowlist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(allowlist), forKey: Self.allowKey)
    }

    // MARK: Download, convert, compile

    private func download(_ l: FilterList) async -> String? {
        do {
            let (data, resp) = try await URLSession.shared.data(from: l.url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw BlockerError.http }
            try await install(id: l.id, text: String(decoding: data, as: UTF8.self), allowEmpty: false)
            return nil
        } catch { return error.localizedDescription }
    }

    /// Converts and compiles. Throws before touching the active list, so the old one survives.
    private func install(id: String, text: String, allowEmpty: Bool) async throws {
        let r = await Task.detached(priority: .userInitiated) {
            ContentBlockerConverter().convertArray(
                rules: Filters.lines(text), safariVersion: SafariVersion.autodetect(),
                advancedBlocking: true, maxJsonSizeBytes: nil, progress: nil)
        }.value
        let store = WKContentRuleListStore.default()!
        if r.safariRulesCount > 0 {
            guard let list = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: r.safariRulesJSON)
            else { throw BlockerError.compile }
            compiled[id] = list
        } else if allowEmpty {
            await Self.remove(id)
            compiled[id] = nil
        } else {
            throw BlockerError.empty  // an error page or junk, not a filter list
        }
        try Data((r.advancedRulesText ?? "").utf8).write(to: advancedURL(id), options: .atomic)
        meta[id] = ListMeta(updated: Date(), safariRules: r.safariRulesCount, sourceRules: r.sourceRulesCount,
                            invalidRules: r.errorsCount, discardedRules: r.discardedSafariRules)
        persistMeta()
    }

    // The store's lookUp/remove have no async overload in the SDK, so wrap the completion handlers.
    private static func lookUp(_ id: String) async -> WKContentRuleList? {
        await withCheckedContinuation { c in
            WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: id) { list, _ in c.resume(returning: list) }
        }
    }

    private static func remove(_ id: String) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: id) { _ in c.resume() }
        }
    }

    private func advancedURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).advanced.txt") }

    /// Cosmetic rules and scriptlets from every list's advanced part. Cheap (spike: 501 rules in <0.1 s).
    private func rebuildEngine() async {
        let rules = ids.compactMap { try? String(contentsOf: advancedURL($0), encoding: .utf8) }.joined(separator: "\n")
        guard !rules.isEmpty else { engine = nil; return }
        do {
            let container = dir.appendingPathComponent("engine", isDirectory: true)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            let ext = try WebExtension(containerURL: container)
            _ = try await Task.detached { try ext.buildFilterEngine(rules: rules) }.value
            engine = ext
            if errors["engine"] != nil, !bundleJS.isEmpty { errors["engine"] = nil }
        } catch { errors["engine"] = "Cosmetic rules: \(error.localizedDescription)" }
    }
}

enum BlockerError: LocalizedError {
    case http, compile, empty
    var errorDescription: String? {
        switch self {
        case .http: "Download failed (server error)"
        case .compile: "Safari rejected the compiled rules"
        case .empty: "The download contained no usable rules"
        }
    }
}
