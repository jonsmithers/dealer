import AppKit

// MARK: - Self-test section: the linked Ghostty matches the pin (issue #35)

extension TerminalWindowController {
    func ghosttyVersionSelfTestSteps(_ t: SelfTestKit) {
        func bannerShowing() -> Bool {
            guard let b = ghosttyBanner else { return false }
            return b.window != nil && !b.isHidden
        }
        var saved: String?

        t.step("ghostty: the linked GhosttyKit is the commit pinned in scripts/ghostty.version", nil, {
            let v = GhosttyVersion.linked
            if GhosttyVersion.commit(of: v) == nil {
                print("  (skipped: libghostty version \"\(v)\" records no commit)")
                return nil
            }
            return GhosttyVersion.mismatch(version: v)
        }) {}

        t.step("ghostty: the pin compiled into the app equals scripts/ghostty.version", nil, {
            guard let file = GhosttyVersion.sourcePin() else { return "can't read scripts/ghostty.version next to the sources" }
            return file == GhosttyVersion.pinnedCommit ? nil
                : "GhosttyVersion.pinnedCommit is \(GhosttyVersion.pinnedCommit), scripts/ghostty.version is \(file)"
        }) {}

        t.step("ghostty: version parsing (commit after `+`, prefix match, no-commit builds pass)", nil, {
            let pin = "243f7df7c131f9cc69bed4bc4586f5bf17b9d4fa"
            var problems: [String] = []
            if GhosttyVersion.commit(of: "1.3.2-main-+243f7df7c") != "243f7df7c" { problems.append("commit parse") }
            if GhosttyVersion.mismatch(version: "1.3.2-main-+243f7df7c", pin: pin) != nil { problems.append("match flagged") }
            if GhosttyVersion.mismatch(version: "1.3.2-main-+822e84272", pin: pin) == nil { problems.append("mismatch missed") }
            if GhosttyVersion.mismatch(version: "1.3.2-dev", pin: pin) != nil { problems.append("no-commit flagged") }
            return problems.isEmpty ? nil : problems.joined(separator: "; ")
        }) {}

        t.step("ghostty: a mismatched framework shows a loud banner", nil, {
            bannerShowing() && (self.ghosttyBanner?.message.contains("822e84272") ?? false)
                ? nil : "banner should show the mismatch (\(self.ghosttyBanner?.message ?? "no banner"))"
        }) {
            saved = GhosttyVersion.problem
            GhosttyVersion.dismissed = false
            GhosttyVersion.problem = GhosttyVersion.mismatch(version: "1.3.2-main-+822e84272")
            self.layoutNow()
        }

        t.step("ghostty: dismissing the banner hides it", nil, { bannerShowing() ? "banner should be hidden" : nil }) {
            self.ghosttyBanner?.dismiss()
            self.layoutNow()
        }

        t.step("ghostty: no banner when the versions match", nil, { bannerShowing() ? "banner should be gone" : nil }) {
            GhosttyVersion.problem = saved
            GhosttyVersion.dismissed = false
            self.layoutNow()
        }
    }
}
