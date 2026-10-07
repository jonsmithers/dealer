import AppKit

/// Finds the Ghostty resources directory (shell integration, themes; terminfo sits next to it)
/// that libghostty reads from `GHOSTTY_RESOURCES_DIR` (#39). Dealer doesn't ship these; it borrows
/// them from an installed Ghostty.app.
///
/// Order: `GHOSTTY_RESOURCES_DIR` when the caller set it (even empty, which means "none"; self-test
/// mode differs, see `apply()`), then in self-test mode the pinned commit's shell integration
/// (`pinnedForSelfTest`), then the app Launch Services knows as `com.mitchellh.ghostty`, then `/Applications` and `~/Applications`. A
/// candidate counts only if it has a `shell-integration/` directory.
enum GhosttyResources {
    static let variable = "GHOSTTY_RESOURCES_DIR"
    static let bundleIdentifier = "com.mitchellh.ghostty"

    enum Source: String {
        case environment = "GHOSTTY_RESOURCES_DIR"
        case pinnedCheckout = "the pinned Ghostty checkout (self-test)"
        case registeredApp = "the Ghostty.app Launch Services knows"
        case applicationsFolder = "an Applications folder"
    }

    struct Resolution: Equatable {
        /// The directory to use, or nil for none.
        var path: String?
        var source: Source?
        /// Candidates looked at and rejected (no `shell-integration/`), in order.
        var rejected: [String] = []
    }

    /// `Contents/Resources/ghostty` of an app bundle.
    static func resourcesDirectory(inApp app: URL) -> String {
        app.appendingPathComponent("Contents/Resources/ghostty").path
    }

    static func isValid(_ dir: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir + "/shell-integration", isDirectory: &isDir) && isDir.boolValue
    }

    /// The lookup itself, free of process state so the self-test can drive it with temp dirs.
    /// `environment` is the variable's current value (nil when unset); `applicationFolders` are
    /// searched for `Ghostty.app` after `registeredApp`.
    static func resolve(environment: String?, pinned: String? = nil, registeredApp: URL?,
                        applicationFolders: [URL]) -> Resolution {
        if let environment {
            // The caller decided; an empty value deliberately means no resources at all
            // (libghostty ignores an empty variable).
            return Resolution(path: environment.isEmpty ? nil : environment, source: .environment)
        }
        var candidates: [(Source, String)] = []
        if let pinned { candidates.append((.pinnedCheckout, pinned)) }
        if let registeredApp { candidates.append((.registeredApp, resourcesDirectory(inApp: registeredApp))) }
        for folder in applicationFolders {
            candidates.append((.applicationsFolder, resourcesDirectory(inApp: folder.appendingPathComponent("Ghostty.app"))))
        }
        var result = Resolution()
        var seen = Set<String>()
        for (source, dir) in candidates where seen.insert(dir).inserted {
            if isValid(dir) { result.path = dir; result.source = source; return result }
            result.rejected.append(dir)
        }
        return result
    }

    /// What `apply()` decided for this process.
    private(set) static var current: Resolution?

    /// Resolves for this process and sets `GHOSTTY_RESOURCES_DIR`. Called once, before `ghostty_init`.
    ///
    /// Self-test mode ignores an inherited `GHOSTTY_RESOURCES_DIR` (any agent running tests in a
    /// Ghostty or Dealer pane inherits one) and prefers the pinned commit's shell integration, so
    /// every run gets the same shells. `DEALER_SELFTEST_RESOURCES` overrides that: a directory, or
    /// empty for no resources at all (how the suite is checked without shell integration, #40).
    @discardableResult
    static func apply() -> Resolution {
        var env = ProcessInfo.processInfo.environment[variable]
        var pinned: String?
        if SelfTest.enabled {
            if let override = SelfTest.env("SELFTEST_RESOURCES") {
                env = override
            } else if let p = pinnedForSelfTest() {
                env = nil
                pinned = p
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let r = resolve(environment: env, pinned: pinned,
                        registeredApp: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
                        applicationFolders: [URL(fileURLWithPath: "/Applications"),
                                             home.appendingPathComponent("Applications")])
        // libghostty reads the variable, and treats an empty one as unset.
        setenv(variable, r.path ?? "", 1)
        switch (r.source, r.path) {
        case (.environment, nil):
            NSLog("Dealer: GHOSTTY_RESOURCES_DIR (or DEALER_SELFTEST_RESOURCES) is empty: running without Ghostty's shell integration, terminfo and themes")
        case (.environment, let path?):
            if !isValid(path) {
                NSLog("Dealer: GHOSTTY_RESOURCES_DIR=%@ has no shell-integration/; using it anyway", path)
            }
        case (let source?, let path?):
            NSLog("Dealer: Ghostty resources: %@ (from %@)", path, source.rawValue)
        default:
            NSLog("Dealer: no Ghostty resources found (looked in %@). Shell integration, terminfo and "
                  + "bundled themes are unavailable: new panes won't follow the shell's directory and "
                  + "a `theme =` naming a Ghostty theme won't load. Install Ghostty.app or set GHOSTTY_RESOURCES_DIR.",
                  r.rejected.joined(separator: ", "))
        }
        current = r
        return r
    }

    // MARK: Self-test: the pinned commit's shell integration

    /// The self-test's resources directory: `src/shell-integration` of the pinned Ghostty commit,
    /// extracted with `git archive` from the Ghostty checkout into a per-pin cache under $TMPDIR,
    /// so test shells get the same integration on every machine, installed Ghostty or not.
    /// terminfo and themes are linked from an installed Ghostty.app when there is one. Nil (and the normal
    /// lookup) when there's no checkout or it lacks the pinned commit.
    static func pinnedForSelfTest() -> String? {
        let pin = GhosttyVersion.pinnedCommit
        let cache = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dealer-ghostty-\(pin.prefix(12))")
        let dir = cache.appendingPathComponent("ghostty").path
        if isValid(dir) { return dir }
        guard let checkout = ghosttyCheckout() else {
            NSLog("Dealer: self-test: no Ghostty checkout found ($GHOSTTY_SRC or ../ghostty); using the installed Ghostty's resources")
            return nil
        }
        let fm = FileManager.default
        let staging = cache.path + ".\(getpid())"
        try? fm.removeItem(atPath: staging)
        do { try fm.createDirectory(atPath: staging + "/ghostty", withIntermediateDirectories: true) } catch { return nil }
        let sh = "git -C \"$1\" archive \"$2\" src/shell-integration | tar -x -C \"$3\" --strip-components 1"
        guard run("/bin/sh", ["-c", sh, "sh", checkout, pin, staging + "/ghostty"]),
              isValid(staging + "/ghostty") else {
            NSLog("Dealer: self-test: couldn't extract %@ from %@; using the installed Ghostty's resources", pin, checkout)
            try? fm.removeItem(atPath: staging)
            return nil
        }
        // Only shell integration is in Ghostty's source tree. Themes (a build dependency) and
        // terminfo (generated; libghostty sets TERMINFO=<dir>/../terminfo) are linked from an
        // installed Ghostty.app when there is one, so a `theme =` in the user's config still loads.
        let installed = [NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
                         URL(fileURLWithPath: "/Applications/Ghostty.app"),
                         fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Ghostty.app")]
            .compactMap { $0?.appendingPathComponent("Contents/Resources") }
            .first { isValid($0.appendingPathComponent("ghostty").path) }
        if let installed {
            try? fm.createSymbolicLink(atPath: staging + "/terminfo", withDestinationPath: installed.appendingPathComponent("terminfo").path)
            try? fm.createSymbolicLink(atPath: staging + "/ghostty/themes", withDestinationPath: installed.appendingPathComponent("ghostty/themes").path)
        }
        // Atomic publish: another self-test may be doing the same; the loser drops its copy.
        if rename(staging, cache.path) != 0 { try? fm.removeItem(atPath: staging) }
        return isValid(dir) ? dir : nil
    }

    /// The Ghostty checkout, found like `scripts/build-ghosttykit.sh`: `$GHOSTTY_SRC`, then a
    /// `ghostty` next to this source tree, then one next to the main checkout (for worktrees).
    static func ghosttyCheckout() -> String? {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var candidates: [String] = []
        if let src = ProcessInfo.processInfo.environment["GHOSTTY_SRC"], !src.isEmpty { candidates.append(src) }
        candidates.append(repo.deletingLastPathComponent().appendingPathComponent("ghostty").path)
        // In a worktree, .git is a file: "gitdir: <main>/.git/worktrees/<name>".
        if let text = try? String(contentsOf: repo.appendingPathComponent(".git"), encoding: .utf8),
           text.hasPrefix("gitdir: ") {
            let gitdir = URL(fileURLWithPath: text.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines))
            let main = gitdir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(main.deletingLastPathComponent().appendingPathComponent("ghostty").path)
        }
        let fm = FileManager.default
        return candidates.first { fm.fileExists(atPath: $0 + "/build.zig") && fm.fileExists(atPath: $0 + "/include/ghostty.h") }
    }

    private static func run(_ exe: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
