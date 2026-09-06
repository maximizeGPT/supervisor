import Foundation

/// Non-trapping stand-in for SwiftPM's synthesized `Bundle.module` accessor,
/// for SupervisorCore's own resource bundle.
///
/// WHY THIS EXISTS. The generated accessor
/// (`.build/*/SupervisorCore.build/DerivedSources/resource_bundle_accessor.swift`)
/// probes exactly two locations and then calls `Swift.fatalError`:
///
///   1. `Bundle.main.bundleURL/Supervisor_SupervisorCore.bundle` — the .app
///      ROOT, i.e. `Supervisor.app/Supervisor_SupervisorCore.bundle`
///   2. a hardcoded absolute build path baked in at compile time,
///      `/Users/main/supervisor/.build/.../Supervisor_SupervisorCore.bundle`
///
/// `Scripts/build-app.sh` embeds the bundle in `Contents/Resources/`, which is
/// NEITHER of those. On the build machine candidate 2 exists and rescues the
/// lookup; on an end user's Mac both miss and the accessor traps. Because
/// `Dispatcher.systemPrompt` is a lazily-initialized static reached on the
/// auto-dispatch path (default ON), that trap is a hard crash the first time
/// the loop thinks — strictly worse than the stub prompt it replaced.
///
/// Same class of bug, same shape of fix, as
/// `OnboardingScene.resourceBundle` (SupervisorUI) and
/// `statusBarResourceBundle` (SupervisorStatusBar): probe the real packaged
/// layouts by hand and return nil when the bundle is genuinely absent, so the
/// caller can degrade instead of dying.
public enum CoreResourceBundle {
    /// Name SwiftPM gives this target's synthesized bundle
    /// (`<PackageName>_<TargetName>.bundle`).
    public static let bundleName = "Supervisor_SupervisorCore.bundle"

    /// Class token for `Bundle(for:)`. Resolves to the binary SupervisorCore
    /// is statically linked into: the app in production, the xctest bundle
    /// under `swift test`.
    private final class BundleToken {}

    /// Candidate directories that may hold the resource bundle, in priority
    /// order. A pure function over its inputs so the search order is
    /// hand-verifiable in a unit test without touching the filesystem.
    ///
    ///   - `mainResourceURL`  → `Supervisor.app/Contents/Resources` (the
    ///     packaged layout build-app.sh actually produces; the one the
    ///     synthesized accessor misses)
    ///   - `mainBundleURL`    → the .app root (what the accessor probes) and,
    ///     for a bare CLI binary, the directory beside it
    ///   - `classResourceURL` / `classBundleURL` → dev + xctest layouts, where
    ///     SwiftPM drops the bundle next to the linked binary
    ///   - `executableURL`    → `Contents/MacOS/` and its sibling
    ///     `Contents/Resources/`, so the lookup still works if `Bundle.main`
    ///     fails to infer the enclosing .app (helper binaries spawned from
    ///     inside `Contents/MacOS/`)
    public static func candidateDirectories(
        mainResourceURL: URL?,
        mainBundleURL: URL,
        classResourceURL: URL?,
        classBundleURL: URL,
        executableURL: URL?
    ) -> [URL] {
        var dirs: [URL] = []
        if let mainResourceURL { dirs.append(mainResourceURL) }
        dirs.append(mainBundleURL)
        if let classResourceURL { dirs.append(classResourceURL) }
        dirs.append(classBundleURL.deletingLastPathComponent())
        if let execDir = executableURL?.deletingLastPathComponent() {
            dirs.append(execDir)
            dirs.append(
                execDir
                    .deletingLastPathComponent()
                    .appendingPathComponent("Resources", isDirectory: true)
            )
        }
        return dirs
    }

    /// The resolved bundle, or nil when it is genuinely absent. NEVER traps.
    public static let resolved: Bundle? = {
        let classBundle = Bundle(for: BundleToken.self)
        let dirs = candidateDirectories(
            mainResourceURL: Bundle.main.resourceURL,
            mainBundleURL: Bundle.main.bundleURL,
            classResourceURL: classBundle.resourceURL,
            classBundleURL: classBundle.bundleURL,
            executableURL: Bundle.main.executableURL
        )
        for dir in dirs {
            let candidate = dir.appendingPathComponent(bundleName, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path),
               let bundle = Bundle(url: candidate) {
                return bundle
            }
        }
        return nil
    }()

    /// Resource lookup that degrades to nil instead of trapping.
    public static func url(forResource name: String, withExtension ext: String) -> URL? {
        resolved?.url(forResource: name, withExtension: ext)
    }
}
