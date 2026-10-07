import AppKit

// MARK: - Self-test section: finding Ghostty's resources directory (issues #39, #41)

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
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
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

        t.step("resources: DEALER_GHOSTTY_RESOURCES_DIR wins over everything, and empty means none", nil, {
            let bundled = dir("bundle/ghostty", valid: true)
            let registered = app("registered/Ghostty.app", valid: true)
            let a = R.resolve(override: "/custom/ghostty", bundled: bundled, inherited: bundled,
                              registeredApp: registered, applicationFolders: [sys])
            let b = R.resolve(override: "", bundled: bundled, registeredApp: registered, applicationFolders: [sys])
            return expect(a, "/custom/ghostty", .override) ?? expect(b, nil, .override)
        }) {}

        t.step("resources: the app's own bundle beats an inherited GHOSTTY_RESOURCES_DIR (#41)", nil, {
            let bundled = dir("bundle/ghostty", valid: true)
            let inherited = dir("other-ghostty/ghostty", valid: true)
            let registered = app("registered/Ghostty.app", valid: true)
            let a = R.resolve(bundled: bundled, vendored: [dir("vendor/ghostty", valid: true)], inherited: inherited,
                              registeredApp: registered, applicationFolders: [sys])
            let b = R.resolve(bundled: nil, inherited: inherited, registeredApp: registered, applicationFolders: [sys])
            return expect(a, bundled, .appBundle) ?? expect(b, inherited, .inherited)
        }) {}

        t.step("resources: then vendor/ (self-test), the inherited variable, Launch Services, folders", nil, {
            let vendored = dir("vendor/ghostty", valid: true)
            let inherited = dir("other-ghostty/ghostty", valid: true)
            let registered = app("registered/Ghostty.app", valid: true)
            _ = app("sys/Applications/Ghostty.app", valid: true)
            let a = R.resolve(vendored: [root.appendingPathComponent("missing").path, vendored], inherited: inherited,
                              registeredApp: registered, applicationFolders: [sys])
            let b = R.resolve(inherited: "", registeredApp: registered, applicationFolders: [sys])
            let c = R.resolve(registeredApp: nil, applicationFolders: [sys])
            return expect(a, vendored, .vendored, rejected: 1)
                ?? expect(b, R.resourcesDirectory(inApp: registered), .registeredApp)
                ?? expect(c, R.resourcesDirectory(inApp: sys.appendingPathComponent("Ghostty.app")), .applicationsFolder)
        }) {}

        t.step("resources: a candidate without shell-integration/ is skipped for /Applications", nil, {
            _ = app("sys/Applications/Ghostty.app", valid: true)
            let r = R.resolve(bundled: dir("bundle-broken/ghostty", valid: false),
                              inherited: dir("inherited-broken/ghostty", valid: false),
                              registeredApp: app("broken/Ghostty.app", valid: false), applicationFolders: [sys, user])
            return expect(r, R.resourcesDirectory(inApp: sys.appendingPathComponent("Ghostty.app")), .applicationsFolder, rejected: 3)
        }) {}

        t.step("resources: ~/Applications is found when /Applications has no Ghostty (#39)", nil, {
            _ = app("home/Applications/Ghostty.app", valid: true)
            let r = R.resolve(registeredApp: nil, applicationFolders: [empty, user])
            return expect(r, R.resourcesDirectory(inApp: user.appendingPathComponent("Ghostty.app")), .applicationsFolder, rejected: 1)
        }) {}

        t.step("resources: nothing valid anywhere gives none, listing every place tried", nil, {
            let r = R.resolve(registeredApp: nil, applicationFolders: [empty, root.appendingPathComponent("x")])
            return expect(r, nil, nil, rejected: 2)
        }) {}

        t.step("resources: this self-test's shells use the pinned build's resources (vendor/ or the app bundle)", nil, {
            defer { try? fm.removeItem(at: root) }
            guard let r = R.current else { return "GhosttyResources.apply() didn't run" }
            if ProcessInfo.processInfo.environment[R.overrideVariable] != nil {
                print("      (DEALER_GHOSTTY_RESOURCES_DIR is set: \(r.path == nil ? "no shell integration" : "a given directory"))")
                return nil
            }
            if r.source == .appBundle {
                // A bundled self-test run (`DEALER_SELFTEST=quit Dealer.app/Contents/MacOS/Dealer`):
                // bundle.sh copied these from vendor/, and libghostty's TERMINFO is next to them.
                guard let path = r.path else { return "no path" }
                return fm.fileExists(atPath: path + "/../terminfo/78/xterm-ghostty") ? nil : "the bundle should hold terminfo"
            }
            guard r.source == .vendored, let path = r.path else {
                print("      (skipped: no vendor/ghostty-resources; shells use \(r.source?.rawValue ?? "no resources"))")
                return nil
            }
            let stamp = (try? String(contentsOfFile: path + "/../ghostty-commit", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return all(ProcessInfo.processInfo.environment[R.variable] == path ? nil : "GHOSTTY_RESOURCES_DIR should be the vendored directory",
                       stamp == GhosttyVersion.pinnedCommit ? nil : "vendor/ghostty-resources is from \(stamp ?? "an unknown commit"), not the pin",
                       fm.fileExists(atPath: path + "/../terminfo/78/xterm-ghostty") ? nil : "terminfo should sit next to it",
                       fm.fileExists(atPath: path + "/themes") ? nil : "themes should be there")
        }) {}
    }
}
