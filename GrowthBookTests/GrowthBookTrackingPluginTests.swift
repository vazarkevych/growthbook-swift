import XCTest
@testable import GrowthBook

// MARK: - MockPlugin

/// Records all plugin calls for use in integration assertions.
final class MockPlugin: GrowthBookPlugin {
    private let lock = NSLock()

    private var _initializedWith: String?
    var initializedWith: String? { lock.lock(); defer { lock.unlock() }; return _initializedWith }

    private var _experimentCallCount = 0
    var experimentCallCount: Int { lock.lock(); defer { lock.unlock() }; return _experimentCallCount }

    private var _featureCallCount = 0
    var featureCallCount: Int { lock.lock(); defer { lock.unlock() }; return _featureCallCount }

    private var _closeCalled = false
    var closeCalled: Bool { lock.lock(); defer { lock.unlock() }; return _closeCalled }

    func initialize(clientKey: String) {
        lock.lock(); defer { lock.unlock() }
        _initializedWith = clientKey
    }
    func onExperimentViewed(experiment: Experiment, result: ExperimentResult) {
        lock.lock(); defer { lock.unlock() }
        _experimentCallCount += 1
    }
    func onFeatureEvaluated(featureKey: String, result: FeatureResult) {
        lock.lock(); defer { lock.unlock() }
        _featureCallCount += 1
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        _closeCalled = true
    }
}

// MARK: - MockURLProtocol

/// Intercepts URLSession requests without making real network calls.
final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) -> Result<(HTTPURLResponse, Data), Error>)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession converts httpBody to httpBodyStream when using URLProtocol.
        // Reconstruct the body so handlers can read request.httpBody normally.
        var enriched = request
        if enriched.httpBody == nil, let stream = request.httpBodyStream {
            var data = Data()
            stream.open()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: 4096)
                guard n > 0 else { break }
                data.append(buf, count: n)
            }
            buf.deallocate()
            stream.close()
            enriched.httpBody = data
        }

        let result = Self.requestHandler?(enriched) ?? .success((
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            Data()
        ))
        switch result {
        case .success(let (response, data)):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Plugin integration tests

/// Tests that MockPlugin receives the correct lifecycle and evaluation events via GrowthBookSDK.
final class GrowthBookPluginIntegrationTests: XCTestCase {

    private let clientKey = "sdk-test-key"

    private func makeSDK(plugins: [GrowthBookPlugin] = [], features: Data? = nil) -> GrowthBookSDK {
        var builder = GrowthBookBuilder(
            apiHost: "https://host.com",
            clientKey: clientKey,
            attributes: ["id": "user-1"],
            features: features,
            trackingCallback: { _, _ in },
            backgroundSync: false,
            ttlSeconds: 60
        )
        .setNetworkDispatcher(networkDispatcher: MockNetworkClient(successResponse: nil, error: nil))
        for plugin in plugins { builder = builder.addPlugin(plugin) }
        return builder.initializer()
    }

    private func featuresPayload() -> Data {
        #"{"features":{"flag-a":{"defaultValue":true}}}"#.data(using: .utf8)!
    }

    // MARK: - Lifecycle

    func testPluginReceivesInitialize() {
        let plugin = MockPlugin()
        _ = makeSDK(plugins: [plugin])
        XCTAssertEqual(plugin.initializedWith, clientKey)
    }

    func testPluginCloseCalledOnSDKDeinit() {
        let plugin = MockPlugin()
        autoreleasepool { _ = makeSDK(plugins: [plugin]) }
        XCTAssertTrue(plugin.closeCalled)
    }

    // MARK: - Experiment events

    func testPluginReceivesOnExperimentViewed() {
        let plugin = MockPlugin()
        let sdk = makeSDK(plugins: [plugin])
        // UUID key avoids ExperimentHelper deduplication across test runs
        let exp = Experiment(key: "plugin-exp-\(UUID().uuidString)", variations: [JSON(0), JSON(1)], coverage: 1.0)
        sdk.run(experiment: exp)
        XCTAssertEqual(plugin.experimentCallCount, 1)
    }

    func testPluginNotCalledWhenUserNotInExperiment() {
        let plugin = MockPlugin()
        let sdk = makeSDK(plugins: [plugin])
        // coverage = 0 → user never assigned → inExperiment = false
        let exp = Experiment(key: "plugin-exp-\(UUID().uuidString)", variations: [JSON(0), JSON(1)], coverage: 0.0)
        sdk.run(experiment: exp)
        XCTAssertEqual(plugin.experimentCallCount, 0)
    }

    // MARK: - Feature events

    func testPluginReceivesOnFeatureEvaluated() {
        let plugin = MockPlugin()
        let sdk = makeSDK(plugins: [plugin], features: featuresPayload())
        _ = sdk.evalFeature(id: "flag-a")
        XCTAssertEqual(plugin.featureCallCount, 1)
    }

    func testPluginReceivesFeatureEvaluatedForUnknownFeature() {
        let plugin = MockPlugin()
        let sdk = makeSDK(plugins: [plugin], features: featuresPayload())
        _ = sdk.evalFeature(id: "nonexistent")
        XCTAssertEqual(plugin.featureCallCount, 1)
    }

    // MARK: - Multiple plugins

    func testMultiplePluginsAllReceiveEvents() {
        let p1 = MockPlugin()
        let p2 = MockPlugin()
        let sdk = makeSDK(plugins: [p1, p2], features: featuresPayload())
        _ = sdk.evalFeature(id: "flag-a")
        XCTAssertEqual(p1.featureCallCount, 1)
        XCTAssertEqual(p2.featureCallCount, 1)
    }

    func testMultiplePluginsAllInitialized() {
        let p1 = MockPlugin()
        let p2 = MockPlugin()
        _ = makeSDK(plugins: [p1, p2])
        XCTAssertEqual(p1.initializedWith, clientKey)
        XCTAssertEqual(p2.initializedWith, clientKey)
    }
}

// MARK: - GrowthBookTrackingPlugin unit tests

final class GrowthBookTrackingPluginTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        MockURLProtocol.requestHandler = nil
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makePlugin(
        batchSize: Int = GrowthBookTrackingPlugin.defaultBatchSize,
        batchTimeout: TimeInterval = GrowthBookTrackingPlugin.defaultBatchTimeout
    ) -> GrowthBookTrackingPlugin {
        GrowthBookTrackingPlugin(batchSize: batchSize, batchTimeout: batchTimeout, urlSession: makeMockSession())
    }

    private func makeExperiment() -> Experiment {
        Experiment(key: "test-exp", variations: [JSON(0), JSON(1)])
    }

    private func makeExperimentResult() -> ExperimentResult {
        ExperimentResult(inExperiment: true, variationId: 1, value: JSON(1),
                         hashAttribute: "id", hashValue: "user-1", key: "1")
    }

    // MARK: - No-op without clientKey

    func testNoOpWithEmptyClientKey() {
        var requestCount = 0
        MockURLProtocol.requestHandler = { _ in
            requestCount += 1
            return .success((HTTPURLResponse(url: URL(string: "https://test.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data()))
        }
        let plugin = makePlugin(batchSize: 1)
        plugin.initialize(clientKey: "")
        plugin.onExperimentViewed(experiment: makeExperiment(), result: makeExperimentResult())
        plugin.close()
        XCTAssertEqual(requestCount, 0)
    }

    // MARK: - Batch size flush

    func testFlushWhenBatchSizeReached() {
        let expectation = expectation(description: "flush on batch size")
        MockURLProtocol.requestHandler = { request in
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["client_key"] as? String, "sdk-test")
            XCTAssertEqual((body["events"] as? [[String: Any]])?.count, 3)
            expectation.fulfill()
            return .success((HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data()))
        }

        let plugin = makePlugin(batchSize: 3, batchTimeout: 60)
        plugin.initialize(clientKey: "sdk-test")
        for _ in 0..<3 {
            plugin.onExperimentViewed(experiment: makeExperiment(), result: makeExperimentResult())
        }
        wait(for: [expectation], timeout: 3.0)
    }

    func testNoFlushBeforeBatchSizeReached() {
        var requestCount = 0
        MockURLProtocol.requestHandler = { _ in
            requestCount += 1
            return .success((HTTPURLResponse(url: URL(string: "https://test.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data()))
        }
        let plugin = makePlugin(batchSize: 5, batchTimeout: 60)
        plugin.initialize(clientKey: "sdk-test")
        for _ in 0..<4 {
            plugin.onExperimentViewed(experiment: makeExperiment(), result: makeExperimentResult())
        }
        // Give any background work a moment, then assert no request was sent
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(requestCount, 0)
        plugin.close()
    }

    // MARK: - Timer flush

    func testTimerTriggersFlush() {
        let expectation = expectation(description: "timer flush")
        MockURLProtocol.requestHandler = { _ in
            expectation.fulfill()
            return .success((HTTPURLResponse(url: URL(string: "https://test.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data()))
        }
        let plugin = makePlugin(batchSize: 100, batchTimeout: 0.1)
        plugin.initialize(clientKey: "sdk-test")
        plugin.onExperimentViewed(experiment: makeExperiment(), result: makeExperimentResult())
        wait(for: [expectation], timeout: 3.0)
    }

    // MARK: - close() synchronous flush

    func testCloseFlushesSynchronously() {
        var requestSent = false
        MockURLProtocol.requestHandler = { _ in
            requestSent = true
            return .success((HTTPURLResponse(url: URL(string: "https://test.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data()))
        }
        let plugin = makePlugin(batchSize: 100, batchTimeout: 60)
        plugin.initialize(clientKey: "sdk-test")
        plugin.onExperimentViewed(experiment: makeExperiment(), result: makeExperimentResult())

        XCTAssertFalse(requestSent, "no request before close()")
        plugin.close()
        XCTAssertTrue(requestSent, "close() must flush synchronously")
    }

    func testCloseWithNoEventsDoesNotSendRequest() {
        var requestCount = 0
        MockURLProtocol.requestHandler = { _ in
            requestCount += 1
            return .success((HTTPURLResponse(url: URL(string: "https://test.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data()))
        }
        let plugin = makePlugin()
        plugin.initialize(clientKey: "sdk-test")
        plugin.close()
        XCTAssertEqual(requestCount, 0)
    }

    // MARK: - Network failure

    func testNetworkFailureDoesNotCrash() {
        MockURLProtocol.requestHandler = { _ in .failure(NSError(domain: "TestNetwork", code: 500)) }
        let plugin = makePlugin(batchSize: 100, batchTimeout: 60)
        plugin.initialize(clientKey: "sdk-test")
        plugin.onExperimentViewed(experiment: makeExperiment(), result: makeExperimentResult())
        plugin.close() // must not crash or deadlock
    }

    // MARK: - Request format

    func testRequestSentToCorrectEndpoint() {
        let expectation = expectation(description: "correct endpoint")
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "\(GrowthBookTrackingPlugin.defaultIngestorHost)/track")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("growthbook-swift-sdk/") == true)
            expectation.fulfill()
            return .success((HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data()))
        }
        let plugin = makePlugin(batchSize: 1)
        plugin.initialize(clientKey: "sdk-test")
        plugin.onExperimentViewed(experiment: makeExperiment(), result: makeExperimentResult())
        wait(for: [expectation], timeout: 3.0)
    }

    func testFeatureEvaluatedEventIncludedInPayload() {
        let expectation = expectation(description: "feature event in payload")
        MockURLProtocol.requestHandler = { request in
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let events = body["events"] as! [[String: Any]]
            XCTAssertEqual(events.first?["event"] as? String, "feature_evaluated")
            XCTAssertEqual(events.first?["featureKey"] as? String, "my-feature")
            expectation.fulfill()
            return .success((HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data()))
        }
        let plugin = makePlugin(batchSize: 1)
        plugin.initialize(clientKey: "sdk-test")
        let featureResult = FeatureResult(value: JSON(true), isOn: true, source: "defaultValue")
        plugin.onFeatureEvaluated(featureKey: "my-feature", result: featureResult)
        wait(for: [expectation], timeout: 3.0)
    }
}
