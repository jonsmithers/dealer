import AppKit

// MARK: - Self-test section: leftover bugs from the #57 audit
//
// Self-contained (`DEALER_SELFTEST_ONLY=audit:`): each group works in a workspace of its own and
// closes it again.

extension TerminalWindowController {
    /// Sends a press and release of mouse button `button` (2 = middle, 3/4 = back/forward) through
    /// the window, at `view`'s centre, or released at `releaseAt` (window coordinates).
    /// NSEvent.mouseEvent can't set a button number, so the events come from CGEvent; a window-less
    /// NSEvent reports its flipped CG location as locationInWindow (as in SelfTestPaneClose).
    /// Returns false when the events couldn't be built as asked.
    @discardableResult
    func otherClickForTest(_ view: NSView, button: Int, releaseAt: CGPoint? = nil) -> Bool {
        guard let window, !view.isHiddenOrHasHiddenAncestor else { return false }
        let p = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        var sent = 0
        for (type, at) in [(CGEventType.otherMouseDown, p), (.otherMouseUp, releaseAt ?? p)] {
            guard let b = CGMouseButton(rawValue: UInt32(button)),
                  let cg = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: at.x, y: mainHeight - at.y), mouseButton: b)
            else { continue }
            cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            guard let e = NSEvent(cgEvent: cg), e.buttonNumber == button,
                  abs(e.locationInWindow.x - at.x) < 1, abs(e.locationInWindow.y - at.y) < 1 else { continue }
            window.sendEvent(e)
            sent += 1
        }
        return sent == 2
    }

    func auditBugsSelfTestSteps(_ t: SelfTestKit) {
        var problem: String?
        func all(_ problems: String?...) -> String? {
            let p = ([problem] + problems).compactMap { $0 }
            return p.isEmpty ? nil : p.joined(separator: "; ")
        }
        func clicks(_ view: NSView?, _ buttons: [Int], what: String) {
            guard let view else { problem = "no \(what) to click"; return }
            for b in buttons where !otherClickForTest(view, button: b) { problem = "couldn't post button \(b) on \(what)" }
        }
        var home: Workspace?
        var testTab: Tab?
        func deckOfTest() -> Deck? { testTab.flatMap { deck(of: $0) } }
        func tabButton() -> TabButton? {
            guard let tab = testTab, let d = deck(of: tab), let i = d.index(of: tab) else { return nil }
            d.view.strip.layoutSubtreeIfNeeded()
            return d.view.strip.buttons.indices.contains(i) ? d.view.strip.buttons[i] : nil
        }

        // 1. Extra mouse buttons: only the middle one closes (#37); back/forward did too (#57).
        t.step("audit: setup, a workspace with two tabs", nil, {
            all(deckOfTest()?.tabs.count == 2 ? nil : "expected two tabs")
        }) {
            problem = nil
            home = self.activeWorkspace
            _ = self.newWorkspace(name: "audit")
            t.named(self.focusedPane, "au0")
            guard let d = self.focusedDeck else { return }
            self.newTab(in: d)
            t.named(self.focusedPane, "au1")
            testTab = d.activeTab
            self.layoutNow()
        }
        t.step("audit: back/forward buttons (3, 4) on a tab don't close it (#57)", nil, {
            all(deckOfTest() != nil ? nil : "the tab was closed by an extra mouse button")
        }) {
            problem = nil
            clicks(tabButton(), [3, 4], what: "tab")
        }
        t.step("audit: a middle press released outside the tab doesn't close it (#57)", nil, {
            all(deckOfTest() != nil ? nil : "the tab was closed by a middle press released elsewhere")
        }) {
            problem = nil
            guard let b = tabButton() else { problem = "no tab button"; return }
            let outside = t.pane("au1").view.convert(CGPoint(x: 60, y: 60), to: nil)
            if !self.otherClickForTest(b, button: 2, releaseAt: outside) { problem = "couldn't post the middle press" }
        }
        t.step("audit: a middle click still closes the tab (#37)", nil, {
            all(deckOfTest() == nil ? nil : "middle-click should close the tab",
                self.focusedDeck?.tabs.count == 1 ? nil : "one tab should be left")
        }) {
            problem = nil
            clicks(tabButton(), [2], what: "tab")
        }

        let sb = workspaceSidebar
        let bar = workspaceBar
        var count = 0
        func row(_ name: String) -> NSView? {
            (0..<self.workspaces.count).lazy.compactMap { sb.row(at: $0) }.first { ($0 as? WorkspaceRow)?.workspace?.name == name }
        }
        func pill(_ name: String) -> NSView? {
            (0..<self.workspaces.count).lazy.compactMap { bar.button(at: $0) }.first { ($0 as? WorkspaceButton)?.workspace?.name == name }
        }
        t.step("audit: back/forward buttons on a sidebar row don't close the workspace (#57)", nil, {
            all(self.workspaces.count == count ? nil : "a workspace was closed: \(count) → \(self.workspaces.count)")
        }) {
            problem = nil
            count = self.workspaces.count
            self.layoutNow()
            clicks(row("audit"), [3, 4], what: "sidebar row")
        }
        t.step("audit: a middle click on a sidebar row still closes it (#37)", nil, {
            all(self.workspaces.count == count - 1 ? nil : "middle-click should close the workspace",
                self.workspaces.contains { $0.name == "audit" } ? "the audit workspace should be gone" : nil)
        }) {
            problem = nil
            clicks(row("audit"), [2], what: "sidebar row")
        }
        t.step("audit: back/forward buttons on a top-bar pill don't close the workspace (#57)", nil, {
            all(self.workspaces.count == count ? nil : "a workspace was closed: \(count) → \(self.workspaces.count)")
        }) {
            problem = nil
            Settings.workspaceSwitcher = .top
            _ = self.newWorkspace(name: "audit-pill")
            count = self.workspaces.count
            self.layoutNow()
            clicks(pill("audit-pill"), [3, 4], what: "pill")
        }
        t.step("audit: a middle click on a pill still closes it (#37)", nil, {
            all(self.workspaces.count == count - 1 ? nil : "middle-click should close the workspace",
                self.workspaces.contains { $0.name == "audit-pill" } ? "the audit-pill workspace should be gone" : nil)
        }) {
            problem = nil
            clicks(pill("audit-pill"), [2], what: "pill")
            Settings.workspaceSwitcher = .sidebar
            if let home { self.activate(home) }
        }

        // 2. typeText escaped each UTF-8 byte as a scalar: "café" arrived as "cafÃ©".
        let tmp = NSTemporaryDirectory() + "dealer-selftest-audit-\(getpid())"
        t.step("audit: typeText sends non-ASCII text intact (#57)", nil, {
            let p = t.pane("au2")
            guard p.surface.surface != nil else {
                print("      (skipped typeText: ghostty couldn't create terminal surfaces here)")
                return nil
            }
            guard p.surface.waitForShell() else { return "the shell never answered" }
            let file = tmp + "/typed.txt"
            p.surface.typeText(" printf '%s\\n' 'café ✓ 日本' > '\(file)'\r")
            var got = ""
            let ok = SelfTest.waitUntil(timeout: 10) {
                got = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
                return got.hasSuffix("\n")
            }
            return ok && got == "café ✓ 日本\n" ? nil : "expected \"café ✓ 日本\", the shell wrote \(got.debugDescription)"
        }) {
            try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            _ = self.newWorkspace(name: "audit-type")
            t.named(self.focusedPane, "au2")
        }

        // 3. `dealer create pane --no-focus` in a zoomed tab left the new pane hidden (and unsized).
        t.step("audit: create pane --no-focus in a zoomed tab unzooms so the new pane shows (#57)", nil, {
            let new = t.pane("au4")
            return all(new.view.isHiddenOrHasHiddenAncestor ? "the new pane is hidden behind the zoom" : nil,
                       t.pane("au3").view.isHiddenOrHasHiddenAncestor ? "the zoomed pane's neighbour should show again" : nil,
                       self.focusedPane === t.pane("au2") ? nil : "focus should stay on au2 (--no-focus)")
        }) {
            problem = nil
            let a = t.pane("au2")
            self.split(a, side: .right)
            t.named(self.focusedPane, "au3")
            self.focus(a)
            self.toggleZoom(nil)
            self.layoutNow()
            if !t.pane("au3").view.isHiddenOrHasHiddenAncestor { problem = "zoom should hide au3 before the create"; return }
            let r = ControlHandler.handle(["cmd": "create", "args": ["target": "pane:\(a.id)", "side": "down", "focus": false]])
            guard r["ok"] as? Bool == true, let id = (r["result"] as? [String: Any])?["pane"] as? Int,
                  let p = ControlHandler.pane(id: id) else { problem = "create failed: \(r["error"] ?? "?")"; return }
            t.named(p, "au4")
        }

        // 4. `~` abbreviation must match a whole path component.
        t.step("audit: dealer list shortens only the home directory itself to ~ (#57)", nil, {
            let home = NSHomeDirectory()
            func pane(_ id: Int, _ cwd: String) -> [String: Any] { ["id": id, "title": "p", "cwd": cwd] }
            let r: [String: Any] = ["windows": [["id": 1, "workspaces": [["id": 1, "name": "w", "decks": [["id": 1, "tabs": [["id": 1, "title": "t",
                "panes": [pane(1, home + "x/p"), pane(2, home + "/p"), pane(3, home)]]]]]]]]]]
            let out = CLI.tree(r)
            return all(out.contains("cwd=\(home)x/p\n") ? nil : "a sibling of home was abbreviated: \(out.debugDescription)",
                       out.contains("cwd=~/p\n") ? nil : "a path under home should start with ~/",
                       out.contains("cwd=~\n") ? nil : "home itself should be ~",
                       WorkingDirectory.tilde("/Users/jonx/p", home: "/Users/jon") == "/Users/jonx/p" ? nil : "tilde(/Users/jonx/p) for home /Users/jon")
        }) { problem = nil }

        // 5. With 7+ decks the window-edge drop preview used a different colour from the new deck.
        var predicted: NSColor?
        t.step("audit: the window-edge drop colour is the new deck's colour, with 7 decks (#57)", nil, {
            guard let predicted, let made = self.locate(t.pane("au5"))?.deck else { return "no prediction or no new deck" }
            return all(self.decks.count == 8 ? nil : "expected 8 decks, got \(self.decks.count)",
                       predicted.hexString == made.color.hexString ? nil
                           : "drop preview \(predicted.hexString) vs the deck it made \(made.color.hexString)")
        }) {
            problem = nil
            _ = self.newWorkspace(name: "audit-decks")
            t.named(self.focusedPane, "au5")
            guard let first = self.focusedDeck, let p = self.focusedPane else { return }
            for _ in 0..<6 {
                _ = self.controlNewDeck(beside: first, side: .left, fraction: 0.1, workingDirectory: nil, command: nil, title: nil, focus: false)
            }
            self.split(p, side: .bottom)
            self.focus(p)
            self.layoutNow()
            predicted = self.drag.highlightColor(.windowEdge(.right))
            self.promote(self.locate(p)!.node, side: .right, evenly: true)
        }
        t.step("audit: clean up the test workspaces", nil, {
            all(self.workspaces.contains { $0.name?.hasPrefix("audit") == true } ? "test workspaces left behind" : nil)
        }) {
            problem = nil
            for ws in self.workspaces where ws.name?.hasPrefix("audit") == true { self.close(workspace: ws) }
            try? FileManager.default.removeItem(atPath: tmp)
        }
    }
}
