import Foundation
import os

/// Live-instance counts of the model and its heavy views (#43). Each counted class calls
/// `LiveObjects.add` in `init` and `remove` in `deinit`. Diagnostics report them, and the
/// self-test (SelfTestMemory.swift) checks they return to baseline after create/close cycles.
///
/// A lock, not main-thread confinement: a `SurfaceView` can be released on a libghostty callback
/// thread (the last reference can be a closure dispatched from there).
enum LiveObjects {
    enum Kind: String, CaseIterable {
        case window, workspace, deck, tab, pane, paneView, deckView, surfaceView
        /// `ghostty_surface_t`s created by `SurfaceView` and not yet freed.
        case ghosttySurface
    }

    private static var lock = os_unfair_lock()
    private static var counts: [Kind: Int] = [:]

    static func add(_ kind: Kind) {
        os_unfair_lock_lock(&lock)
        counts[kind, default: 0] += 1
        os_unfair_lock_unlock(&lock)
    }

    static func remove(_ kind: Kind) {
        os_unfair_lock_lock(&lock)
        counts[kind, default: 0] -= 1
        os_unfair_lock_unlock(&lock)
    }

    static func count(_ kind: Kind) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return counts[kind] ?? 0
    }

    static var snapshot: [Kind: Int] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0, counts[$0] ?? 0) })
    }

    /// e.g. `window=1 workspace=2 … ghosttySurface=7`.
    static var summary: String {
        let s = snapshot
        return Kind.allCases.map { "\($0.rawValue)=\(s[$0] ?? 0)" }.joined(separator: " ")
    }
}
