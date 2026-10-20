import XCTest
@testable import AqaraMenuBar

final class EventHistoryTests: XCTestCase {
    @MainActor
    func testPaginationPreservesLoadedEventsAndStopsOnEmptyPage() async throws {
        let model = DoorbellModel()
        let day = Calendar.current.startOfDay(for: Date())
        let start = Int64(day.timeIntervalSince1970 * 1000)
        func event(_ time: Int64) -> AqaraCloud.CameraEvent {
            AqaraCloud.parseEvents(["result": ["cameraFileList": [
                ["deviceId": "test", "triggerTime": time, "path": "\(time)/"]
            ]]])[0]
        }
        var ends: [Int64] = []
        model.historyLoader = { lower, upper in
            XCTAssertEqual(lower, start)
            ends.append(upper)
            switch ends.count {
            case 1: return [event(start + 200), event(start + 100)]
            case 2: return [event(start + 50)]
            default: return []
            }
        }
        model.changeHistoryDay(day)
        while model.historyLoading { await Task.yield() }
        model.loadOlderEvents()
        while model.historyLoading { await Task.yield() }
        XCTAssertEqual(ends[1], start + 99)
        model.mergeEvents([event(start + 200), event(start + 300)])
        XCTAssertEqual(model.events.map { $0.event.triggerTime }, [300, 200, 100, 50].map { start + $0 })
        model.loadOlderEvents()
        while model.historyLoading { await Task.yield() }
        XCTAssertEqual(ends[2], start + 49)
        XCTAssertFalse(model.historyHasMore)
        XCTAssertEqual(model.events.count, 4)
    }
}
