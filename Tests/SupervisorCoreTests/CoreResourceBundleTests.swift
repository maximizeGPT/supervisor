import XCTest
@testable import SupervisorCore

/// Guards the install-path fix for the dispatcher system prompt.
///
/// SwiftPM's synthesized `Bundle.module` accessor probes the .app ROOT and a
/// build-machine-absolute path, then calls `fatalError`. `build-app.sh` embeds
/// the resource bundle in `Contents/Resources/`, which is neither, so on every
/// machine except the build machine the accessor traps — and it traps from
/// `Dispatcher.systemPrompt`, a static reached on the default-ON auto-dispatch
/// path. `CoreResourceBundle` replaces it with a non-trapping probe.
final class CoreResourceBundleTests: XCTestCase {

    /// The packaged layout build-app.sh actually produces must be searched.
    /// This is the whole point of the type: `Contents/Resources` is the
    /// directory the synthesized accessor never looks in.
    func testPackagedAppResourcesDirectoryIsSearched() {
        let app = URL(fileURLWithPath: "/Applications/Supervisor.app")
        let contents = app.appendingPathComponent("Contents")
        let dirs = CoreResourceBundle.candidateDirectories(
            mainResourceURL: contents.appendingPathComponent("Resources"),
            mainBundleURL: app,
            classResourceURL: nil,
            classBundleURL: contents.appendingPathComponent("MacOS/Supervisor"),
            executableURL: contents.appendingPathComponent("MacOS/Supervisor")
        )
        let paths = dirs.map(\.path)
        XCTAssertTrue(paths.contains("/Applications/Supervisor.app/Contents/Resources"),
                      "the packaged Contents/Resources layout must be a candidate; it is the only one that exists on a user's Mac")
    }

    /// A helper binary spawned from inside `Contents/MacOS/` may fail to infer
    /// the enclosing .app. The executable-relative `../Resources` probe covers
    /// that, so the companions resolve the prompt even then.
    func testExecutableRelativeResourcesIsSearchedWhenMainBundleIsWrong() {
        let exe = URL(fileURLWithPath: "/Applications/Supervisor.app/Contents/MacOS/SupervisorHeartbeat")
        let dirs = CoreResourceBundle.candidateDirectories(
            mainResourceURL: nil,
            mainBundleURL: URL(fileURLWithPath: "/Applications/Supervisor.app/Contents/MacOS"),
            classResourceURL: nil,
            classBundleURL: exe,
            executableURL: exe
        )
        let paths = dirs.map(\.path)
        XCTAssertTrue(paths.contains("/Applications/Supervisor.app/Contents/MacOS"),
                      "the directory beside the binary must be searched (dev layout)")
        XCTAssertTrue(paths.contains("/Applications/Supervisor.app/Contents/Resources"),
                      "the executable-relative ../Resources probe must be searched")
    }

    /// The .app root the synthesized accessor probes stays in the list — the
    /// fix widens the search, it does not move it.
    func testAppRootRemainsACandidate() {
        let app = URL(fileURLWithPath: "/Applications/Supervisor.app")
        let dirs = CoreResourceBundle.candidateDirectories(
            mainResourceURL: nil,
            mainBundleURL: app,
            classResourceURL: nil,
            classBundleURL: app,
            executableURL: nil
        )
        XCTAssertTrue(dirs.map(\.path).contains("/Applications/Supervisor.app"))
    }

    /// Nil inputs must not crash and must not synthesize garbage candidates.
    /// The resolver's contract is "return nil", never "trap".
    func testAllOptionalInputsAbsentIsSafe() {
        let dirs = CoreResourceBundle.candidateDirectories(
            mainResourceURL: nil,
            mainBundleURL: URL(fileURLWithPath: "/nonexistent"),
            classResourceURL: nil,
            classBundleURL: URL(fileURLWithPath: "/nonexistent"),
            executableURL: nil
        )
        XCTAssertFalse(dirs.isEmpty)
    }

    /// The resource lookup itself must go through the non-trapping resolver.
    /// Under `swift test` the bundle sits next to the xctest binary, so this
    /// also proves the class-bundle candidates cover the test layout.
    func testResolverFindsTheDispatcherPromptUnderTest() {
        XCTAssertNotNil(CoreResourceBundle.resolved,
                        "SupervisorCore's resource bundle must resolve under the test layout")
        XCTAssertNotNil(CoreResourceBundle.url(forResource: "dispatcher-system-prompt", withExtension: "txt"))
    }
}
