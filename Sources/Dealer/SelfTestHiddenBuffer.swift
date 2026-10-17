import AppKit
import GhosttyKit
import IOSurface

// MARK: - Self-test section: panes created out of view hold no window-sized buffer (issue #53)

extension TerminalWindowController {
    /// A pane created out of view (a background tab, another workspace, a restored session) used to
    /// draw one frame at its real size before the layout occluded it, and its layer kept that frame's
    /// IOSurface (one window-sized buffer, ~25 MB at 3020×2036 px) until it was first shown. Surfaces
    /// now start occluded and the layout unoccludes the panes it shows.
    /// Panes made here are never `named`: the self-test's name table holds panes strongly.
    func hiddenBufferSelfTestSteps(_ t: SelfTestKit) {
        /// The IOSurface ghostty's layer presents, if it has drawn a frame.
        func presented(_ p: Pane) -> IOSurfaceRef? {
            guard let c = p.surface.layer?.contents, CFGetTypeID(c as CFTypeRef) == IOSurfaceGetTypeID() else { return nil }
            return (c as! IOSurfaceRef)
        }
        func backingSize(_ p: Pane) -> CGSize { p.surface.convertToBacking(p.surface.bounds.size) }

        var created: [Pane] = []
        var tabs: [Tab] = []
        var workspace: Workspace?
        var result: (perPane: Double, buffer: Double, drawn: Int)?
        var skipped = false

        t.step("memory: panes created out of view allocate no window-sized buffer until shown (#53)", nil, {
            if skipped { return nil }  // printed why
            guard let r = result else { return "no measurement" }
            let mb = { (b: Double) in String(format: "%.1f MB", b / 1_048_576) }
            if r.drawn > 0 { return "\(r.drawn) of \(created.count) panes created out of view drew a frame (their layers hold a buffer)" }
            let limit = max(0.25 * r.buffer, 4 * 1_048_576)
            return r.perPane < limit ? nil
                : "each pane created out of view costs \(mb(r.perPane)) (a window-sized buffer is \(mb(r.buffer)), limit \(mb(limit)))"
        }) {
            guard let deck = self.focusedDeck, let shown = self.focusedPane, shown.surface.surface != nil else {
                skipped = true
                print("      (skipped: no live surface, screen locked?)")
                return
            }
            self.layoutNow()
            let px = backingSize(shown)
            let buffer = Double(px.width * px.height * 4)
            guard buffer > 3 * 1_048_576 else {
                skipped = true
                print("      (skipped: pane too small to tell, \(px))")
                return
            }
            // GPU memory only when the kernel reports it (task_vm_info's graphics ledger): new shells
            // add heap noise of a few MB each to the whole footprint.
            let graphicsLedger = Diagnostics.memory().graphics > 0
            func footprint() -> Double {
                let m = Diagnostics.memory()
                return Double(graphicsLedger ? m.graphics : m.footprint)
            }
            // Earlier steps' closed panes free their memory on other threads; start from a settled
            // reading, or that release would hide this step's growth.
            var last = footprint()
            _ = SelfTest.waitUntil(timeout: 3) {
                _ = SelfTest.waitUntil(timeout: 0.25) { false }
                let now = footprint()
                defer { last = now }
                return abs(now - last) < 1_048_576
            }
            let base = footprint()
            for _ in 0..<3 {
                let p = self.controlNewTab(in: deck, after: nil, workingDirectory: nil, command: nil, title: nil, focus: false)
                created.append(p)
                if let tab = self.locate(p)?.tab { tabs.append(tab) }
            }
            let ws0 = self.controlNewWorkspace(after: nil, name: "hidden-buffer", workingDirectory: nil, command: nil,
                                               title: nil, focus: false)
            created.append(ws0)
            workspace = self.workspace(of: ws0)
            if let ws = workspace, let d = ws.decks.first {
                created.append(self.controlNewDeck(beside: d, side: .right, fraction: 0.5, workingDirectory: nil,
                                                   command: nil, title: nil, focus: false))
            }
            self.layoutNow()
            // Before the fix each one drew a frame at its real size within a few hundred ms (the
            // shell's first output). Give them that long, then measure.
            _ = SelfTest.waitUntil(timeout: 1.5) { created.allSatisfy { presented($0) != nil } }
            let perPane = max(0, footprint() - base) / Double(created.count)
            result = (perPane, buffer, created.filter { presented($0) != nil }.count)
            print(String(format: "      (%d panes created out of view: %.1f MB each of \(graphicsLedger ? "graphics" : "whole") footprint; a window-sized buffer: %.1f MB; %d drew a frame)",
                         created.count, perPane / 1_048_576, buffer / 1_048_576, result!.drawn))
        }

        t.step("memory: a pane created out of view draws at its real size when first shown (#45, #53)", nil, {
            if skipped { return nil }
            guard let deck = self.focusedDeck, let tab = tabs.first, let p = tab.panes.first else { return "no background tab" }
            // While hidden it already has its real grid (#45), and nothing drawn.
            let target = backingSize(p)
            guard let s = p.surface.surface else { return "no surface" }
            let hiddenSize = ghostty_surface_size(s)
            if hiddenSize.columns < 20 { return "hidden pane's grid is \(hiddenSize.columns)×\(hiddenSize.rows), not its real size" }
            if p.surface.isEffectivelyVisible { return "background pane reports itself visible" }
            self.select(tab: tab, in: deck)
            self.layoutNow()
            if !p.surface.isEffectivelyVisible { return "shown pane is still occluded" }
            if let failure = SelfTest.waitUntil("the shown pane to present a frame", timeout: 5, { presented(p) != nil }) {
                return failure
            }
            let io = presented(p)!
            let (w, h) = (IOSurfaceGetWidth(io), IOSurfaceGetHeight(io))
            let after = ghostty_surface_size(s)
            print("      (hidden grid \(hiddenSize.columns)×\(hiddenSize.rows), shown \(after.columns)×\(after.rows); frame \(w)×\(h) px for a \(Int(target.width))×\(Int(target.height)) px view)")
            if abs(CGFloat(w) - target.width) > 1 || abs(CGFloat(h) - target.height) > 1 {
                return "first frame is \(w)×\(h) px, the pane is \(Int(target.width))×\(Int(target.height)) px"
            }
            if after.columns != hiddenSize.columns || after.rows != hiddenSize.rows {
                return "grid changed on first show: \(hiddenSize.columns)×\(hiddenSize.rows) → \(after.columns)×\(after.rows)"
            }
            return nil
        }) {}

        var leftovers: [WeakRef<Pane>] = []
        t.step("memory: clean up the panes created out of view", nil, {
            leftovers.contains { $0.value != nil } ? "panes created out of view outlived their close" : nil
        }) {
            autoreleasepool {
                tabs.forEach { self.close(tab: $0) }
                if let ws = workspace, self.workspaces.contains(where: { $0 === ws }) { self.close(workspace: ws) }
                self.layoutNow()
                leftovers = created.map { WeakRef($0) }
                created = []
                tabs = []
                workspace = nil
            }
        }
    }
}
