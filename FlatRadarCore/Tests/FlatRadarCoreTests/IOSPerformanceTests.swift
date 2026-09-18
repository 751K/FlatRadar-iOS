import XCTest
@testable import FlatRadarCore

@MainActor
final class IOSPerformanceTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ values: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: values))
    }
    private func map(_ id: String, city: String = "A", lat: Double = 52, lng: Double = 5,
                     status: String = "Available to book") throws -> MapListing {
        try decode(MapListing.self, ["id": id, "name": id, "status": status,
                                     "city": city, "lat": lat, "lng": lng])
    }

    func testMapCachesCountsAndVisibleResultsAndInvalidatesEqualSizedChanges() throws {
        let store = MapStore()
        store.listings = [try map("a"), try map("b", city: "B", status: "Occupied")]
        store.cityFilter = "A"
        for _ in 0..<20 {
            XCTAssertEqual(store.visibleCount, 1)
            XCTAssertEqual(store.visibleListings.map(\.id), ["a"])
            XCTAssertEqual(store.statusCounts[.book], 1)
        }
        XCTAssertEqual(store.visibilityComputations, 1)
        XCTAssertEqual(store.statusComputations, 1)
        store.cityFilter = "B"
        XCTAssertEqual(store.visibleListings.map(\.id), ["b"])
        XCTAssertEqual(store.visibilityComputations, 2)
        store.listings = [try map("replacement", city: "B")]
        XCTAssertEqual(store.visibleListings.map(\.id), ["replacement"])
        XCTAssertEqual(store.statusCounts[.book], 1)
        XCTAssertNil(store.statusCounts[.occupied])
        store.focusExtra = try map("deep-link", city: "Outside")
        XCTAssertEqual(store.visibleCount, 1)
        XCTAssertEqual(store.visibleListings.map(\.id), ["replacement", "deep-link"])
        store.clear()
        XCTAssertTrue(store.visibleListings.isEmpty)
        XCTAssertTrue(store.statusCounts.isEmpty)
    }

    func testCalendarRangeAndGroupingFollowReplacementMutationAndClear() throws {
        func item(_ id: String, _ date: String) throws -> CalendarListing {
            try decode(CalendarListing.self, ["id": id, "name": id, "status": "book", "available_from": date])
        }
        let store = CalendarStore()
        let first = try item("a", "2026-09-01")
        let last = try item("b", "2026-10-01")
        store.listings = [last, first, try item("bad", "invalid")]
        XCTAssertEqual(store.dateRange?.start, first.date)
        XCTAssertEqual(store.dateRange?.end, last.date)
        XCTAssertEqual(store.listings(on: try XCTUnwrap(first.date)).map(\.id), ["a"])
        store.listings.removeAll { $0.id == "a" }
        XCTAssertEqual(store.dateRange?.start, last.date)
        store.clear()
        XCTAssertNil(store.dateRange)
        XCTAssertTrue(store.listingsByDay.isEmpty)
    }

    func testCachedListingDatePreservesTimezoneFormatsAndAgeBoundary() throws {
        for date in ["2026-09-18T10:00:00Z", "2026-09-18T10:00:00.000Z", "2026-09-18 12:00:00"] {
            let listing = try decode(Listing.self, ["id": "a", "name": "A", "status": "book", "first_seen": date])
            let parsed = try XCTUnwrap(listing.firstSeenDate)
            XCTAssertEqual(parsed, try Date.ISO8601FormatStyle().parse("2026-09-18T10:00:00Z"))
            XCTAssertTrue(listing.isNew(asOf: parsed.addingTimeInterval(86399)))
            XCTAssertFalse(listing.isNew(asOf: parsed.addingTimeInterval(86400)))
        }
        let invalid = try decode(Listing.self, ["id": "a", "name": "A", "status": "book", "first_seen": "invalid"])
        XCTAssertNil(invalid.firstSeenDate)
    }

    func testViewportCullsDistantPinsButKeepsBufferAndDeepLink() throws {
        let viewport = MapViewport(latitude: 52, longitude: 5, latitudeDelta: 0.1, longitudeDelta: 0.1)
        let listings = [try map("center"), try map("buffer", lat: 52.06), try map("far", lat: 53)]
        XCTAssertEqual(viewport.listings(from: listings).map(\.id), ["center", "buffer"])
        XCTAssertEqual(viewport.listings(from: listings, preservingID: "far").count, 3)
        XCTAssertTrue(viewport.contains(MapViewport(latitude: 52.01, longitude: 5,
                                                  latitudeDelta: 0.1, longitudeDelta: 0.1, padding: 1)))
        XCTAssertFalse(viewport.contains(MapViewport(latitude: 52.04, longitude: 5,
                                                   latitudeDelta: 0.1, longitudeDelta: 0.1, padding: 1)))
    }

    func testViewportHandlesDateLineAndWorld() {
        let edge = MapViewport(latitude: 0, longitude: 179, latitudeDelta: 10, longitudeDelta: 6, padding: 1)
        XCTAssertTrue(edge.contains(latitude: 0, longitude: -179))
        XCTAssertFalse(edge.contains(latitude: 0, longitude: -170))
        let world = MapViewport(latitude: 0, longitude: 0, latitudeDelta: 180, longitudeDelta: 360, padding: 1)
        XCTAssertTrue(world.contains(latitude: 90, longitude: -180))
        XCTAssertTrue(world.contains(edge))
    }

    func testLargeMapReusesDerivedResultsAndOnlySubmitsNearbyListings() throws {
        let store = MapStore()
        store.listings = try (0..<2000).map {
            try map("L\($0)", lat: 52 + Double($0 % 40) * 0.05,
                    lng: 5 + Double($0 / 40) * 0.05)
        }
        let coldStart = Date()
        _ = store.visibleListings
        _ = store.statusCounts
        let coldMS = Date().timeIntervalSince(coldStart) * 1000
        let hotStart = Date()
        for _ in 0..<100 {
            XCTAssertEqual(store.visibleCount, 2000)
            XCTAssertEqual(store.visibleListings.count, 2000)
            XCTAssertEqual(store.statusCounts[.book], 2000)
        }
        let hotMS = Date().timeIntervalSince(hotStart) * 1000 / 100
        XCTAssertEqual(store.visibilityComputations, 1)
        XCTAssertEqual(store.statusComputations, 1)
        let viewport = MapViewport(latitude: 52, longitude: 5, latitudeDelta: 0.1, longitudeDelta: 0.1)
        XCTAssertEqual(viewport.listings(from: store.visibleListings).count, 4)
        print(String(format: "IOS_MAP_2000 initial=%.3fms cached_reads=%.4fms viewport=4/2000", coldMS, hotMS))
    }

    func testInitialListingsLoadSkipsInFlightAndSuccessfulEmptyResult() async throws {
        let store = ListingsStore()
        var calls = 0
        var held: CheckedContinuation<ListingsResponse, Error>?
        store.loadPage = { _ in
            calls += 1
            return try await withCheckedThrowingContinuation { held = $0 }
        }
        let first = Task { await store.loadIfNeeded() }
        for _ in 0..<1000 where held == nil { await Task.yield() }
        await store.loadIfNeeded()
        XCTAssertEqual(calls, 1)
        held?.resume(returning: try decode(ListingsResponse.self,
                                           ["items": [], "total": 0, "limit": 50, "offset": 0]))
        await first.value
        await store.loadIfNeeded()
        XCTAssertEqual(calls, 1)
        store.clear()
        store.loadPage = { _ in calls += 1; throw URLError(.notConnectedToInternet) }
        await store.loadIfNeeded()
        await store.loadIfNeeded()
        XCTAssertEqual(calls, 3, "失败后允许再次加载")
    }

    func testMapInitialLoadSharesGuardAndClearInvalidatesOldResponse() async throws {
        let store = MapStore()
        var calls = 0
        var held: CheckedContinuation<MapResponse, Error>?
        store.loadMap = {
            calls += 1
            return try await withCheckedThrowingContinuation { held = $0 }
        }
        let first = Task { await store.loadIfNeeded() }
        for _ in 0..<1000 where held == nil { await Task.yield() }
        await store.loadIfNeeded()
        XCTAssertEqual(calls, 1)
        store.clear()
        let empty = try decode(MapResponse.self, ["listings": [], "uncached": 0])
        held?.resume(returning: empty)
        await first.value
        store.loadMap = { calls += 1; return empty }
        await store.loadIfNeeded()
        await store.loadIfNeeded()
        XCTAssertEqual(calls, 2, "清除后允许重载，成功的空结果不再重复预热")
    }
}
