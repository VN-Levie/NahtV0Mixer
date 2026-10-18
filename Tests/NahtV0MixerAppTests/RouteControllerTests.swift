import XCTest
@testable import NahtV0MixerApp

final class RouteControllerTests: XCTestCase {
    func testStoppingQueuedEnableDoesNotLeaveInterfaceBusy() async throws {
        try await MainActor.run {
            let name = "NahtV0Mixer.tests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(true, forKey: "mixerEnabled")
            let store = MixerStore(defaults: defaults)
            XCTAssertFalse(store.isMixerEnabled, "Opening the app must start in bypass")
            store.setMixerEnabled(true)
            store.shutdown()
            XCTAssertFalse(store.isBusy)
        }
    }
    func testNoFramesTearsDownButSilentFramesRemainHealthy() async {
        let route = FakeRoute()
        route.processedFrameCount = 0
        var time: TimeInterval = 0
        let controller = RouteController(now: { time }, makeRoute: { _ in route })
        let initial = await apply(controller, ["app": request()])
        XCTAssertTrue(initial.0.isEmpty, "A graph without rendered frames isn't controlled yet")
        time = 5
        let stalled = await apply(controller, ["app": request()])
        XCTAssertEqual(route.stopCount, 1)
        XCTAssertNotNil(stalled.1["app"])
        controller.stopAll()

        let silent = FakeRoute()
        let healthy = RouteController(now: { time }, makeRoute: { _ in silent })
        _ = await apply(healthy, ["app": request()])
        time = 10; silent.processedFrameCount += 48000
        let result = await apply(healthy, ["app": request()])
        XCTAssertEqual(result.0, ["app"])
        XCTAssertTrue(result.1.isEmpty)
        healthy.stopAll()
    }
    private func request(output: UInt32 = 10, gain: Float = 0.5) -> RouteRequest {
        RouteRequest(processIDs: [1, 2], outputID: output, sampleRate: 48_000, gain: gain)
    }
    func testGainUpdateReusesRouteAndBypassStopsIt() async {
        let route = FakeRoute()
        var creations = 0
        let controller = RouteController { _ in creations += 1; return route }
        let first = await apply(controller, ["app": request()])
        XCTAssertEqual(first.0, ["app"])
        _ = await apply(controller, ["app": request(gain: 0.2)])
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(route.gain, 0.2)
        let stopped = await apply(controller, [:])
        XCTAssertTrue(stopped.0.isEmpty)
        XCTAssertEqual(route.stopCount, 1)
        controller.stopAll()
        XCTAssertEqual(route.stopCount, 1)
    }
    func testChangedOutputRebuildsEvenWhenPreviousDeviceIsGone() async {
        let first = FakeRoute(), second = FakeRoute()
        var creations = 0
        let controller = RouteController { _ in creations += 1; return creations == 1 ? first : second }
        _ = await apply(controller, ["app": request()])
        first.configurationIsCurrent = false
        let result = await apply(controller, ["app": request(output: 20)])
        XCTAssertEqual(creations, 2)
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(result.0, ["app"])
        XCTAssertTrue(result.1.isEmpty)
        controller.stopAll()
    }
    func testFailureDoesNotRetryEveryRefreshAndExplicitRetryWorks() async {
        struct Failed: Error {}
        var creations = 0
        let controller = RouteController { _ in creations += 1; throw Failed() }
        let first = await apply(controller, ["app": request()])
        XCTAssertFalse(first.1.isEmpty)
        _ = await apply(controller, ["app": request()])
        XCTAssertEqual(creations, 1)
        _ = await apply(controller, ["app": request()], retry: true)
        XCTAssertEqual(creations, 2)
        controller.stopAll()
    }
    func testRenderFailureStopsRouteAndReportsIt() async {
        let route = FakeRoute()
        let controller = RouteController { _ in route }
        _ = await apply(controller, ["app": request()])
        route.hasRenderFailure = true
        let result = await apply(controller, ["app": request()])
        XCTAssertTrue(result.0.isEmpty)
        XCTAssertNotNil(result.1["app"])
        XCTAssertEqual(route.stopCount, 1)
        controller.stopAll()
    }
    private func apply(_ controller: RouteController, _ requests: [String: RouteRequest], retry: Bool = false) async -> (Set<String>, [String: String]) {
        await withCheckedContinuation { continuation in
            controller.apply(requests, retry: retry) { continuation.resume(returning: ($0, $1)) }
        }
    }
}

private final class FakeRoute: MixerAudioRoute {
    var processedFrameCount: UInt64 = 1
    var hasRenderFailure = false
    var configurationIsCurrent = true
    var gain: Float = 1
    var stopCount = 0
    func setGain(_ gain: Float) { self.gain = gain }
    func stop() { stopCount += 1 }
}
