import AppKit

// MARK: - Self-test section: settings.toml (issue #10)
//
// Runs against the temp config home `Settings.start()` picks in self-test mode, never the user's
// ~/.config/dealer. The environment and legacy UserDefaults are faked per step.

extension TerminalWindowController {
    func settingsSelfTestSteps(_ t: SelfTestKit) {
        let fm = FileManager.default
        func url() -> URL { Settings.fileURL }
        func write(_ text: String) {
            try? fm.createDirectory(at: url().deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url(), atomically: false, encoding: .utf8)
        }
        func read() -> String { (try? String(contentsOf: url(), encoding: .utf8)) ?? "<missing>" }
        func all(_ problems: String?...) -> String? {
            let p = problems.compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func eq<T: Equatable>(_ a: T, _ b: T, _ what: String) -> String? { a == b ? nil : "\(what): got \(a), expected \(b)" }
        /// Lets the file watcher (main-queue dispatch sources) run until `cond` holds.
        func waitUntil(_ timeout: TimeInterval = 3, _ cond: () -> Bool) {
            let end = Date().addingTimeInterval(timeout)
            while !cond() && Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        }
        func topBarShowing() -> Bool { !workspaceBar.isHidden && workspaceSidebar.isHidden }
        func bannerShowing() -> Bool { settingsBanner.window != nil && !settingsBanner.isHidden }

        t.step("settings: the file lives under $XDG_CONFIG_HOME/dealer, else ~/.config/dealer", nil, {
            all(eq(Settings.defaultFileURL(environment: ["XDG_CONFIG_HOME": "/tmp/x"]).path, "/tmp/x/dealer/settings.toml", "XDG"),
                eq(Settings.defaultFileURL(environment: [:], home: "/Users/u").path, "/Users/u/.config/dealer/settings.toml", "default"),
                eq(Settings.defaultFileURL(environment: ["XDG_CONFIG_HOME": "rel"], home: "/Users/u").path,
                   "/Users/u/.config/dealer/settings.toml", "relative XDG is ignored"),
                url().path.hasPrefix(fm.temporaryDirectory.path) ? nil : "self-test must use a temp config home, not \(url().path)")
        }) {}
        t.step("settings: docs/settings.example.toml matches the built-in example", nil, {
            let doc = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("docs/settings.example.toml")
            guard let text = try? String(contentsOf: doc, encoding: .utf8) else { return nil }  // source tree not present
            return all(text == SettingsFile.exampleText ? nil : "docs/settings.example.toml differs from SettingsFile.exampleText",
                       TOML.parse(text).problems.isEmpty ? nil : "the example should parse cleanly")
        }) {}
        t.step("settings: the TOML subset parses (arrays, escapes, dotted keys, comments)", nil, {
            let d = TOML.parse("""
            a = 1_000 # c
            b.c = 'lit\\eral'
            [t]
            s = "q\\"\\u00e9\\n"
            arr = [
              "x", # one
              "y",
            ]
            f = -1.5
            on = false
            [u.v]
            n = [[1, 2], [3]]
            """)
            return all(eq(d.problems, [], "problems"),
                       eq(d.values["a"], .integer(1000), "a"), eq(d.values["b.c"], .string("lit\\eral"), "b.c"),
                       eq(d.values["t.s"], .string("q\"é\n"), "t.s"), eq(d.values["t.arr"], .array([.string("x"), .string("y")]), "t.arr"),
                       eq(d.values["t.f"], .float(-1.5), "t.f"), eq(d.values["t.on"], .bool(false), "t.on"),
                       eq(d.values["u.v.n"], .array([.array([.integer(1), .integer(2)]), .array([.integer(3)])]), "u.v.n"),
                       eq(d.lines["t.f"], 9, "line of t.f"))
        }) {}
        t.step("settings: no file means defaults, with the old UserDefaults values as a fallback", nil, {
            all(eq(Settings.agentCommand, "codex", "agent command"), eq(Settings.workspaceSwitcher, .top, "switcher"),
                eq(Settings.agentInjectHooks, false, "legacy bool"),
                topBarShowing() ? nil : "open windows should apply the migrated switcher",
                fm.fileExists(atPath: self.path(url())) ? "reading must not create the file" : nil)
        }) {
            try? fm.removeItem(at: url())
            let old: [String: Any] = ["agentCommand": "codex", "workspaceSwitcher": "top", "agentInjectHooks": "false"]
            Settings.legacy = { old[$0] }
            Settings.reload(force: true)
        }
        t.step("settings: the file beats the old defaults; DEALER_AGENT_COMMAND beats the file", nil, {
            all(eq(Settings.workspaceSwitcher, .sidebar, "switcher from the file"), !topBarShowing() ? nil : "sidebar mode should apply",
                eq(Settings.agentCommand, "envcmd", "env var wins"), eq(Settings.agentInjectHooks, false, "inject_hooks"))
        }) {
            write("[agent]\ncommand = \"aider\"\ninject_hooks = false\n[workspaces]\nswitcher = \"sidebar\"\n")
            Settings.reload()
            let fileCmd = Settings.agentCommand
            Settings.environment = ["DEALER_AGENT_COMMAND": "envcmd"]
            if fileCmd != "aider" { Settings.environment = ["DEALER_AGENT_COMMAND": "file says \(fileCmd)"] }
        }
        t.step("settings: a malformed file keeps the good keys, defaults the bad ones, and shows a banner", nil, {
            let p = Settings.problems
            return all(eq(Settings.agentCommand, "aider", "good key"), eq(Settings.agentInjectHooks, true, "bad bool → default"),
                       eq(Settings.workspaceSwitcher, .sidebar, "bad switcher → default"),
                       eq(p.count, 4, "problem count (\(p))"),
                       p.contains { $0.hasPrefix("line 3: agent.inject_hooks must be true or false") } ? nil : "wrong-type problem missing",
                       p.contains { $0.hasPrefix("line 5: workspaces.switcher must be a string") } ? nil : "switcher problem missing",
                       p.contains { $0.hasPrefix("line 6: unknown setting workspaces.bogus") } ? nil : "unknown-key problem missing",
                       p.contains { $0.hasPrefix("line 7:") } ? nil : "syntax problem missing",
                       bannerShowing() ? nil : "the banner should show",
                       self.settingsBanner.message.contains("4 problems") ? nil : "banner text: \(self.settingsBanner.message)")
        }) {
            Settings.environment = [:]
            Settings.legacy = { _ in nil }
            write("[agent]\ncommand = \"aider\"\ninject_hooks = \"yes\"\n[workspaces]\nswitcher = 3\nbogus = true\nthis is not toml\n")
            Settings.reload()
        }
        t.step("settings: dismissing the banner hides it", nil, { bannerShowing() ? "banner should be hidden" : nil }) {
            self.settingsBanner.dismiss()
            self.layoutNow()
        }
        t.step("settings: an editor's atomic save (write + rename) is picked up live", nil, {
            all(eq(Settings.workspaceSwitcher, .top, "switcher"), topBarShowing() ? nil : "open window should switch to pills",
                eq(Settings.problems, [], "problems"), bannerShowing() ? "banner should be gone" : nil)
        }) {
            let tmp = url().deletingLastPathComponent().appendingPathComponent(".settings.toml.swp")
            try? "[workspaces]\nswitcher = \"top\"\n".write(to: tmp, atomically: false, encoding: .utf8)
            _ = Darwin.rename(self.path(tmp), self.path(url()))
            waitUntil { topBarShowing() }
        }
        t.step("settings: an in-place write is picked up live too", nil, {
            all(eq(Settings.workspaceSwitcher, .sidebar, "switcher"), !topBarShowing() ? nil : "window should go back to the sidebar")
        }) {
            if let h = FileHandle(forWritingAtPath: self.path(url())) {
                h.truncateFile(atOffset: 0)
                h.write(Data("[workspaces]\nswitcher = \"sidebar\"\n".utf8))
                h.closeFile()
            }
            waitUntil { !topBarShowing() }
        }
        let mine = "# mine\n[agent]\ncommand = \"aider\"   # keep\n\n[workspaces]\nswitcher   =   \"sidebar\"  # where\n\n[future]\nx = 1\n"
        t.step("settings: a menu toggle rewrites only its own value", nil, {
            all(eq(read(), mine.replacingOccurrences(of: "\"sidebar\"  # where", with: "\"top\"  # where"), "file"),
                eq(Settings.workspaceSwitcher, .top, "switcher"), topBarShowing() ? nil : "pills should show")
        }) {
            write(mine)
            Settings.reload()
            self.useTopBarSwitcher(nil)
        }
        t.step("settings: a missing key goes into its table, a missing table is appended", nil, {
            let intoExample = SettingsFile.rewrite(SettingsFile.exampleText, key: "agent.inject_hooks", literal: "false")
            return all(eq(read(), "[agent]\ncommand = \"x\"\n\n[workspaces]\nswitcher = \"sidebar\"\n", "appended table"),
                       intoExample.contains("# inject_hooks = true\ninject_hooks = false\n") ? nil : "should land under its commented example",
                       eq(TOML.parse(intoExample).values["agent.inject_hooks"], .bool(false), "parsed back"))
        }) {
            write("[agent]\ncommand = \"x\"\n")
            Settings.reload()
            self.useSidebarSwitcher(nil)
        }
        t.step("settings: with no file, a menu toggle creates it from the example", nil, {
            let text = read()
            return all(text.hasPrefix("# Dealer settings.") ? nil : "should start from the example",
                       text.contains("# switcher = \"sidebar\"\nswitcher = \"top\"\n") ? nil : "value should sit under its example line",
                       eq(Settings.problems, [], "problems"), eq(Settings.workspaceSwitcher, .top, "switcher"))
        }) {
            try? fm.removeItem(at: url())
            Settings.reload()
            self.useTopBarSwitcher(nil)
        }
        t.step("settings: clean up (no file, sidebar)", nil, {
            all(eq(Settings.workspaceSwitcher, .sidebar, "switcher"), !topBarShowing() ? nil : "sidebar mode expected")
        }) {
            try? fm.removeItem(at: url())
            Settings.reload()
        }
    }

    private func path(_ u: URL) -> String { u.path }
}
