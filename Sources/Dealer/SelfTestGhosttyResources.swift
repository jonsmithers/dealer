import AppKit

// MARK: - Self-test section: finding Ghostty's resources directory (issue #39)

extension TerminalWindowController {
    func ghosttyResourcesSelfTestSteps(_ t: SelfTestKit) {
        // Fake installs in a temp dir: an app is valid only with a shell-integration/ directory.
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dealer-resources-test-\(getpid())")
        func app(_ path: String, valid: Bool) -> URL {
            let url = root.appendingPathComponent(path)
            let res = url.appendingPathComponent("Contents/Resources/ghostty")
            try? fm.createDirectory(at: valid ? res.appendingPathComponent("shell-integration") : res, withIntermediateDirectories: true)
            return url
        }
        func dir(_ path: String, valid: Bool) -> String {
            let url = root.appendingPathComponent(path)
            try? fm.createDirectory(at: valid ? url.appendingPathComponent("shell-integration") : url, withIntermediateDirectories: true)
            return url.path
        }
        typealias R = GhosttyResources
        let sys = root.appendingPathComponent("sys/Applications")
        let user = root.appendingPathComponent("home/Applications")
        let empty = root.appendingPathComponent("nowhere/Applications")
        func expect(_ r: R.Resolution, _ path: String?, _ source: R.Source?, rejected: Int? = nil) -> String? {
            var problems: [String] = []
            if r.path != path { problems.append("path \(r.path ?? "nil"), expected \(path ?? "nil")") }
            if r.source != source { problems.append("source \(r.source?.rawValue ?? "nil"), expected \(source?.rawValue ?? "nil")") }
            if let rejected, r.rejected.count != rejected { problems.append("rejected \(r.rejected), expected \(rejected)") }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }

        t.step("resources: GHOSTTY_RESOURCES_DIR wins, and set-but-empty means none", nil, {
            let registered = app("registered/Ghostty.app", valid: true)
            _ = app("sys/Applications/Ghostty.app", valid: true)
            let pinned = dir("pinned/ghostty", valid: true)
            let a = R.resolve(environment: "/custom/ghostty", pinned: pinned, registeredApp: registered, applicationFolders: [sys])
            let b = R.resolve(environment: "", pinned: pinned, registeredApp: registered, applicationFolders: [sys])
            return expect(a, "/custom/ghostty", .environment) ?? expect(b, nil, .environment)
        }) {}

        t.step("resources: the pinned checkout (self-test), then the app Launch Services knows", nil, {
            let registered = app("registered/Ghostty.app", valid: true)
            let pinned = dir("pinned/ghostty", valid: true)
            let a = R.resolve(environment: nil, pinned: pinned, registeredApp: registered, applicationFolders: [sys, user])
            let b = R.resolve(environment: nil, pinned: nil, registeredApp: registered, applicationFolders: [sys, user])
            return expect(a, pinned, .pinnedCheckout)
                ?? expect(b, R.resourcesDirectory(inApp: registered), .registeredApp)
        }) {}

        t.step("resources: a candidate without shell-integration/ is skipped for /Applications", nil, {
            _ = app("sys/Applications/Ghostty.app", valid: true)
            let broken = app("broken/Ghostty.app", valid: false)
            let pinned = dir("pinned-broken/ghostty", valid: false)
            let r = R.resolve(environment: nil, pinned: pinned, registeredApp: broken, applicationFolders: [sys, user])
            return expect(r, R.resourcesDirectory(inApp: sys.appendingPathComponent("Ghostty.app")), .applicationsFolder, rejected: 2)
        }) {}

        t.step("resources: ~/Applications is found when /Applications has no Ghostty (#39)", nil, {
            _ = app("home/Applications/Ghostty.app", valid: true)
            let r = R.resolve(environment: nil, registeredApp: nil, applicationFolders: [empty, user])
            return expect(r, R.resourcesDirectory(inApp: user.appendingPathComponent("Ghostty.app")), .applicationsFolder, rejected: 1)
        }) {}

        t.step("resources: nothing valid anywhere gives none, listing every place tried", nil, {
            let r = R.resolve(environment: nil, registeredApp: nil, applicationFolders: [empty, root.appendingPathComponent("x")])
            return expect(r, nil, nil, rejected: 2)
        }) {}

        t.step("resources: this self-test's shells use the pinned commit's shell integration", nil, {
            defer { try? fm.removeItem(at: root) }
            guard let r = R.current else { return "GhosttyResources.apply() didn't run" }
            if SelfTest.env("SELFTEST_RESOURCES") != nil {
                print("      (DEALER_SELFTEST_RESOURCES is set: \(r.path == nil ? "no shell integration" : "a given directory"))")
                return nil
            }
            guard r.source == .pinnedCheckout else {
                print("      (skipped: no Ghostty checkout with the pinned commit; shells use \(r.source?.rawValue ?? "no resources"))")
                return nil
            }
            let live = ProcessInfo.processInfo.environment[R.variable]
            guard let path = r.path, live == path, R.isValid(path),
                  path.contains(String(GhosttyVersion.pinnedCommit.prefix(12))) else {
                return "GHOSTTY_RESOURCES_DIR should be the pinned cache"
            }
            return nil
        }) {}
    }
}
