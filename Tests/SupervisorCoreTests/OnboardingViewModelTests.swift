// OnboardingViewModelTests.swift
//
// Exhaustive over the state machine. Uses a stub PermissionChecker, the
// in-memory APIKeyStore, and the URLProtocol-mocked AnthropicClient from
// AnthropicClientTests so we can deterministically drive every branch.

import XCTest
@testable import SupervisorCore

@MainActor
final class OnboardingViewModelTests: XCTestCase {

    // MARK: - Stub PermissionChecker

    final class StubChecker: PermissionChecker, @unchecked Sendable {
        var ax: Bool = false
        var notif: NotificationAuthStatus = .notDetermined
        var screen: Bool = false
        var requestAXReturn: Bool = false
        var requestNotifResult: Result<Bool, Error> = .success(false)
        var promptedCount = 0

        func isAXGranted() -> Bool { ax }
        func notificationStatus() async -> NotificationAuthStatus { notif }
        func isScreenRecordingGranted() -> Bool { screen }
        func requestAX(prompt: Bool) -> Bool {
            if prompt { promptedCount += 1 }
            return requestAXReturn
        }
        func requestNotifications() async throws -> Bool {
            try requestNotifResult.get()
        }
        func snapshot() async -> PermissionSnapshot {
            .init(ax: ax, notifications: notif, screenRecording: screen)
        }
    }

    // MARK: - Helpers

    nonisolated(unsafe) static var canned: [String: (Int, Data, [String: String])] = [:]

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [OnboardingMockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func makeVM(
        permissions: StubChecker = StubChecker(),
        keyStore: ProviderKeyStore = InMemoryProviderKeyStore(),
        activeProviderStore: ActiveProviderStore = InMemoryActiveProviderStore()
    ) -> (OnboardingViewModel, StubChecker, ProviderKeyStore) {
        let session = mockSession()
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-onboarding-\(UUID().uuidString).log"))
        let vm = OnboardingViewModel(
            permissions: permissions,
            keyStore: keyStore,
            activeProviderStore: activeProviderStore,
            clientFactory: { provider, key in
                LLMClient(
                    provider: provider,
                    apiKey: key,
                    redactor: DefaultRedactor(),
                    baseURL: URL(string: "https://mock.anthropic.test")!,
                    session: session,
                    traceLog: trace
                )
            },
            trace: trace
        )
        return (vm, permissions, keyStore)
    }

    override func setUp() {
        super.setUp()
        Self.canned.removeAll()
    }

    private static let validResponse: Data = Data(#"""
    {"id":"msg_01","type":"message","role":"assistant","model":"claude-haiku-4-5-20251001","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":1}}
    """#.utf8)

    // MARK: - Init resume points

    func testInitWithNoKeyStartsAtKeyEntry() {
        let (vm, _, _) = makeVM()
        XCTAssertEqual(vm.state, .keyEntry())
    }

    func testInitWithKeyAndNoAXStartsAtAXCheck() throws {
        let store = InMemoryProviderKeyStore()
        try store.write("sk-ant-existing", for: .anthropic)
        let checker = StubChecker()
        checker.ax = false
        let (vm, _, _) = makeVM(permissions: checker, keyStore: store)
        XCTAssertEqual(vm.state, .axCheck())
    }

    func testInitWithKeyAndAXStartsAtAXCheckPendingRefresh() throws {
        // We don't synchronously check notifications in init (it's async);
        // we start at axCheck and let the view's first tick advance us.
        let store = InMemoryProviderKeyStore()
        try store.write("sk-ant-existing", for: .anthropic)
        let checker = StubChecker()
        checker.ax = true
        let (vm, _, _) = makeVM(permissions: checker, keyStore: store)
        XCTAssertEqual(vm.state, .axCheck())
    }

    // MARK: - Key submission

    func testSubmitValidKeyAdvancesToAXCheck() async throws {
        Self.canned["/v1/messages"] = (200, Self.validResponse, [:])
        let (vm, _, store) = makeVM()
        await vm.submitKey("sk-ant-real-shape-key-1234567890")
        XCTAssertEqual(vm.state, .axCheck())
        XCTAssertEqual(try store.read(.anthropic), "sk-ant-real-shape-key-1234567890")
    }

    func testSubmitInvalidKeySurfacesInlineError() async {
        Self.canned["/v1/messages"] = (
            401,
            Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8),
            [:]
        )
        let (vm, _, _) = makeVM()
        await vm.submitKey("sk-ant-bad")
        if case .keyEntry(let err) = vm.state, case .invalidKey = err! {
            // ok
        } else {
            XCTFail("expected keyEntry(invalidKey), got \(vm.state)")
        }
    }

    func testSubmitEmptyKeyFlagsAsInvalid() async {
        let (vm, _, _) = makeVM()
        await vm.submitKey("    ")
        if case .keyEntry(let err) = vm.state, case .invalidKey = err! {
            // ok
        } else {
            XCTFail("expected keyEntry(invalidKey), got \(vm.state)")
        }
    }

    func testSubmitKeyRateLimitedSurfacesRetryAfter() async {
        Self.canned["/v1/messages"] = (
            429,
            Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow"}}"#.utf8),
            ["retry-after": "30"]
        )
        let (vm, _, _) = makeVM()
        await vm.submitKey("sk-ant-x")
        if case .keyEntry(let err) = vm.state, case .rateLimit(let r) = err! {
            XCTAssertEqual(r, 30)
        } else {
            XCTFail("expected keyEntry(rateLimit), got \(vm.state)")
        }
    }

    func testSubmitKeyNetworkFailureSurfacesNetworkError() async {
        // No canned response → MockURLProtocol returns a typed network error.
        Self.canned.removeAll()
        let (vm, _, _) = makeVM()
        await vm.submitKey("sk-ant-anything")
        if case .keyEntry(let err) = vm.state, case .network = err! {
            // ok
        } else {
            XCTFail("expected keyEntry(network), got \(vm.state)")
        }
    }

    func testClearKeyErrorReturnsToCleanState() async {
        Self.canned["/v1/messages"] = (401, Data(#"{"type":"error","error":{"type":"x","message":"y"}}"#.utf8), [:])
        let (vm, _, _) = makeVM()
        await vm.submitKey("sk-ant-bad")
        // Re-entering the field would clear the inline error.
        vm.clearKeyError()
        XCTAssertEqual(vm.state, .keyEntry())
    }

    func testRetryAfterFailureWithFixedKeySucceeds() async throws {
        // Confirm the spec: junk key → typed error inline → user retries
        // without restarting onboarding.
        Self.canned["/v1/messages"] = (401, Data(#"{"type":"error","error":{"type":"x","message":"bad"}}"#.utf8), [:])
        let (vm, _, store) = makeVM()
        await vm.submitKey("sk-ant-bad")
        if case .keyEntry = vm.state { /* ok */ } else { XCTFail("\(vm.state)") }

        // Now switch the canned to success and re-submit with the "fixed" key.
        Self.canned["/v1/messages"] = (200, Self.validResponse, [:])
        await vm.submitKey("sk-ant-good-key-with-real-shape-1234")
        XCTAssertEqual(vm.state, .axCheck())
        XCTAssertEqual(try store.read(.anthropic), "sk-ant-good-key-with-real-shape-1234")
    }

    // MARK: - AX step

    func testPromptForAXOnlyShowsOnce() {
        let checker = StubChecker()
        checker.ax = false
        let (vm, _, _) = makeVM(permissions: checker, keyStore: {
            let s = InMemoryProviderKeyStore()
            try? s.write("sk-ant-x", for: .anthropic)
            return s
        }())
        XCTAssertEqual(vm.state, .axCheck())
        vm.promptForAX()
        vm.promptForAX()
        vm.promptForAX()
        XCTAssertEqual(checker.promptedCount, 1)
    }

    func testRecheckAXAdvancesWhenGranted() async {
        let checker = StubChecker()
        checker.ax = false
        checker.notif = .authorized
        let store = InMemoryProviderKeyStore()
        try? store.write("sk-ant-x", for: .anthropic)
        let (vm, _, _) = makeVM(permissions: checker, keyStore: store)
        XCTAssertEqual(vm.state, .axCheck())

        await vm.recheckAX()
        XCTAssertEqual(vm.state, .axCheck())  // still pending

        // User grants AX out-of-band in System Settings:
        checker.ax = true
        await vm.recheckAX()
        XCTAssertEqual(vm.state, .notifCheck(status: .authorized))
    }

    // MARK: - Notifications step

    func testFinishNotificationStepAuthorizedNotDegraded() async {
        let checker = StubChecker()
        checker.ax = true
        checker.notif = .authorized
        let store = InMemoryProviderKeyStore()
        try? store.write("sk-ant-x", for: .anthropic)
        let (vm, _, _) = makeVM(permissions: checker, keyStore: store)

        await vm.recheckAX()
        XCTAssertEqual(vm.state, .notifCheck(status: .authorized))

        vm.finishNotificationStep()
        XCTAssertEqual(vm.state, .complete(notifDegraded: false))
    }

    func testFinishNotificationStepDeniedFlagsDegradation() async {
        let checker = StubChecker()
        checker.ax = true
        checker.notif = .denied
        let store = InMemoryProviderKeyStore()
        try? store.write("sk-ant-x", for: .anthropic)
        let (vm, _, _) = makeVM(permissions: checker, keyStore: store)

        await vm.recheckAX()
        vm.finishNotificationStep()
        XCTAssertEqual(vm.state, .complete(notifDegraded: true))
    }

    func testFinishNotificationStepProvisionalNotDegraded() async {
        let checker = StubChecker()
        checker.ax = true
        checker.notif = .provisional
        let store = InMemoryProviderKeyStore()
        try? store.write("sk-ant-x", for: .anthropic)
        let (vm, _, _) = makeVM(permissions: checker, keyStore: store)

        await vm.recheckAX()
        vm.finishNotificationStep()
        XCTAssertEqual(vm.state, .complete(notifDegraded: false))
    }

    func testRequestNotificationsThatThrowsCode1IsHandledAsDenied() async {
        // Spike-2-shape failure: requestAuthorization throws Code=1.
        let checker = StubChecker()
        checker.ax = true
        checker.notif = .denied  // status after request reflects what macOS now says
        checker.requestNotifResult = .failure(NSError(domain: "UNErrorDomain", code: 1))
        let store = InMemoryProviderKeyStore()
        try? store.write("sk-ant-x", for: .anthropic)
        let (vm, _, _) = makeVM(permissions: checker, keyStore: store)

        await vm.recheckAX()
        XCTAssertEqual(vm.state, .notifCheck(status: .denied))

        await vm.requestNotifications()
        // The viewmodel must NOT crash on Code=1; it re-polls and reflects
        // the resulting (denied) status.
        if case .notifCheck(let s) = vm.state {
            XCTAssertEqual(s, .denied)
        } else {
            XCTFail("\(vm.state)")
        }
    }

    // MARK: - Step number for progress bar

    func testStepNumbers() {
        XCTAssertEqual(OnboardingState.keyEntry().step, 1)
        XCTAssertEqual(OnboardingState.keyValidating.step, 1)
        XCTAssertEqual(OnboardingState.axCheck().step, 2)
        XCTAssertEqual(OnboardingState.notifCheck(status: .denied).step, 3)
        XCTAssertEqual(OnboardingState.complete(notifDegraded: false).step, 4)
    }
}

// MARK: - URL protocol mock (parallel to AnthropicClientTests')

private final class OnboardingMockURLProtocol: URLProtocol {

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        guard let (status, body, headers) = OnboardingViewModelTests.canned[path] else {
            let err = NSError(domain: NSURLErrorDomain,
                              code: NSURLErrorResourceUnavailable,
                              userInfo: [NSLocalizedDescriptionKey: "no canned: \(path)"])
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        let resp = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
