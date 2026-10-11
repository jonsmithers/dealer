import AppKit
import GhosttyKit

// MARK: - Self-test section: panes of a minimized window are occluded (#54)
//
// The rule (SurfaceView, "Occlusion"): a pane is drawn only when the layout shows it AND its
// window is visible. Minimizing a second window must occlude all its panes, without resizing them
// or stopping their shells, attention or jobs; restoring it brings back exactly the layout's
// visible panes. If the window server doesn't minimize the window here (it may not, e.g. on a
// locked screen), the steps drive the same rule through `WindowVisibility.overrides` and say so.

extension TerminalWindowController {
    func occlusionSelfTestSteps(_ t: SelfTestKit) {
        weak var wc: TerminalWindowController?
        var a: Pane?, b: Pane?, c: Pane?, job: Pane?
        var forced = false
        var sizes: [ObjectIdentifier: (NSSize, UInt16)] = [:]
        var footprintShown: UInt64 = 0

        func panes() -> [Pane] { wc?.allDecks.flatMap(\.tabs).flatMap(\.panes) ?? [] }
        func name(_ p: Pane) -> String { p === a ? "oA" : p === b ? "oB" : p === c ? "oC" : p === job ? "oJob" : "pane \(p.id)" }
        func drawn(_ want: [Pane?], hidden: [Pane?]) -> String? {
            var bad: [String] = []
            for case let p? in want where !p.surface.isEffectivelyVisible { bad.append("\(name(p)) should be drawn") }
            for case let p? in hidden where p.surface.isEffectivelyVisible { bad.append("\(name(p)) should be occluded") }
            return bad.isEmpty ? nil : bad.joined(separator: "; ")
        }
        func setWindowShown(_ shown: Bool) {
            guard let w = wc?.window else { return }
            if forced {
                if shown { WindowVisibility.overrides.removeObject(forKey: w) } else { WindowVisibility.overrides.setObject(NSNumber(value: false), forKey: w) }
                panes().forEach { $0.surface.updateWindowVisibility() }
                return
            }
            if shown { w.deminiaturize(nil) } else { w.miniaturize(nil) }
            if SelfTest.waitUntil(timeout: 5, { w.isMiniaturized != shown }) { return }
            // No window server cooperation: test the rule with a forced answer instead.
            print("      (the window didn't \(shown ? "deminiaturize" : "miniaturize") here; forcing its visibility through WindowVisibility.overrides)")
            forced = true
            setWindowShown(shown)
        }
        func call(_ cmd: String, _ args: [String: Any], caller: Pane? = nil) -> [String: Any]? {
            var req: [String: Any] = ["cmd": cmd, "args": args]
            if let caller { req["caller"] = caller.id }
            let r = ControlHandler.handle(req)
            return r["ok"] as? Bool == true ? r["result"] as? [String: Any] : nil
        }
        var live: Bool { a?.surface.surface != nil }

        t.step("occlusion: a second window with a split and a background tab draws only the split", nil, {
            drawn([a, b], hidden: [c])
        }) {
            let start = Diagnostics.memory().footprint
            AppDelegate.shared.newWindow(nil)
            guard let w = AppDelegate.shared.windowControllers.last, w !== self, let deck = w.focusedDeck else { return }
            wc = w
            w.window?.animationBehavior = .none
            w.newTab(in: deck)
            c = w.focusedPane
            guard let first = deck.tabs.first else { return }
            w.select(tab: first, in: deck)
            a = w.focusedPane
            if let a { w.split(a, side: .right) }
            b = w.focusedPane
            w.layoutNow()
            w.window?.makeKeyAndOrderFront(nil)
            _ = SelfTest.waitUntil(timeout: 3) { drawn([a, b], hidden: [c]) == nil }
            // Let the two shown panes allocate their render targets (3 window-sized buffers each).
            if let a {
                let px = a.surface.convertToBacking(a.surface.bounds.size)
                let buffer = UInt64(max(0, px.width * px.height * 4))
                _ = SelfTest.waitUntil(timeout: 3) { Diagnostics.memory().footprint > start + 4 * buffer }
            }
            footprintShown = Diagnostics.memory().footprint
        }

        t.step("occlusion: minimizing the window occludes all its panes, without resizing them", nil, {
            let resized = [a, b, c].compactMap { $0 }.filter { p in
                guard let (size, cols) = sizes[ObjectIdentifier(p)] else { return false }
                return p.view.frame.size != size || (p.surface.surface.map { ghostty_surface_size($0).columns } ?? cols) != cols
            }
            return [drawn([], hidden: [a, b, c]),
                    resized.isEmpty ? nil : "resized: \(resized.map(name))"].compactMap { $0 }.joined(separator: "; ").nilIfBlank
        }) {
            for case let p? in [a, b, c] {
                sizes[ObjectIdentifier(p)] = (p.view.frame.size, p.surface.surface.map { ghostty_surface_size($0).columns } ?? 0)
            }
            setWindowShown(false)
            _ = SelfTest.waitUntil(timeout: 3) { drawn([], hidden: [a, b, c]) == nil }
            // The GPU swap chains go on the render threads; report what came back (not asserted:
            // the split's size depends on the screen).
            let before = footprintShown
            _ = SelfTest.waitUntil(timeout: 2) { Diagnostics.memory().footprint + 8_000_000 < before }
            let after = Diagnostics.memory().footprint
            print(String(format: "      (footprint %.0f → %.0f MB)", Double(before) / 1_048_576, Double(after) / 1_048_576))
        }

        t.step("occlusion: while minimized, shells run, attention is marked, and a job's failure is reported", nil, {
            guard let a, let b else { return "no panes" }
            var bad: [String] = []
            if a.attention != .waiting { bad.append("oA should be marked waiting, is \(a.attention.name)") }
            if let job {
                if job.surface.isEffectivelyVisible { bad.append("the job's new pane in the minimized window should be occluded") }
                if live, job.attention != .failed { bad.append("the job pane should be marked failed, is \(job.attention.name)") }
            } else { bad.append("the job pane wasn't created") }
            if live, !b.surface.screenText.contains("occl-42") { bad.append("oB's shell output didn't arrive: \(b.surface.screenText.suffix(80).debugDescription)") }
            return bad.isEmpty ? nil : bad.joined(separator: "; ")
        }) {
            guard let a, let b else { return }
            _ = call("notify", ["target": "\(a.id)", "state": "waiting", "title": "t", "body": "b"])
            if let id = call("run", ["command": "false", "placement": "split"], caller: a)?["pane"] as? Int {
                job = ControlHandler.pane(id: id)
            }
            if live, let s = b.surface.surface {
                b.surface.perform("text:" + ControlHandler.escapeForBinding("echo occl-$((6*7))"))
                try? ControlHandler.parseKey("enter").send(to: s)
                _ = SelfTest.waitUntil(timeout: 10) { b.surface.screenText.contains("occl-42") && job?.attention == .failed }
            } else {
                print("      (no live shells: output and the job's report weren't exercised)")
            }
        }

        t.step("occlusion: restoring the window draws the layout's panes again; the background tab stays occluded", nil, {
            drawn([a, b, job], hidden: [c])
        }) {
            setWindowShown(true)
            _ = SelfTest.waitUntil(timeout: 3) { drawn([a, b, job], hidden: [c]) == nil }
        }

        t.step("occlusion: clean up the second window", nil, {
            wc == nil || wc?.window?.isVisible == false ? nil : "the second window is still open"
        }) {
            if let w = wc?.window { WindowVisibility.overrides.removeObject(forKey: w); w.close() }
            self.window?.makeKeyAndOrderFront(nil)
        }
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
