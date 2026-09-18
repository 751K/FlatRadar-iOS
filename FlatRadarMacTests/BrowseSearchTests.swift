import XCTest
import FlatRadarCore
@testable import FlatRadarMac

@MainActor
final class BrowseSearchTests: XCTestCase {
    @MainActor private final class Gate {
        var inputs: [BrowseModel.RowsInput] = []
        var pending: [Int: CheckedContinuation<[Listing], Error>] = [:]
        func filter(_ input: BrowseModel.RowsInput) async throws -> [Listing] {
            let index = inputs.count
            inputs.append(input)
            return try await withCheckedThrowingContinuation { pending[index] = $0 }
        }
        func finish(_ index: Int, rows: [Listing]) {
            pending.removeValue(forKey: index)?.resume(returning: rows)
        }
        func cancelAll() {
            let held = pending.values
            pending = [:]
            for continuation in held { continuation.resume(throwing: CancellationError()) }
        }
    }

    private func listing(_ id: String, city: String = "Amsterdam", name: String? = nil) throws -> Listing {
        let values: [String: Any] = ["id": id, "name": name ?? id, "city": city,
                                     "status": "Available to book", "feature_map": ["building": "Campus"]]
        return try JSONDecoder().decode(Listing.self, from: JSONSerialization.data(withJSONObject: values))
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2000 {
            if condition() { return }
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }

    func testRapidTypingOnlyComputesFinalSearchAndClearingIsImmediate() async throws {
        let model = BrowseModel()
        model.listings.listings = [try listing("a")]
        model.searchText = "A"
        let first = Task { await model.updateRows() }
        await Task.yield()
        first.cancel()
        model.searchText = "Am"
        let second = Task { await model.updateRows() }
        await Task.yield()
        second.cancel()
        model.searchText = "Amsterdam"
        await model.updateRows()
        await first.value
        await second.value
        XCTAssertEqual(model.rowsComputeCount, 1)
        XCTAssertEqual(model.rows.map(\.id), ["a"])
        model.searchText = "missing"
        XCTAssertTrue(model.isFiltering)
        XCTAssertTrue(model.rows.isEmpty)
        model.searchText = ""
        XCTAssertFalse(model.isFiltering)
        XCTAssertEqual(model.rows.map(\.id), ["a"])
    }

    func testOlderSearchCannotReplaceNewerResult() async throws {
        let model = BrowseModel()
        let gate = Gate()
        defer { gate.cancelAll() }
        model.filterRows = { try await gate.filter($0) }
        let a = try listing("a"), b = try listing("b")
        model.listings.listings = [a, b]
        model.searchText = "a"
        let old = Task { await model.updateRows(debounce: false) }
        await waitUntil { gate.inputs.count == 1 }
        model.searchText = "b"
        let current = Task { await model.updateRows(debounce: false) }
        await waitUntil { gate.inputs.count == 2 }
        gate.finish(1, rows: [b])
        await current.value
        gate.finish(0, rows: [a])
        await old.value
        XCTAssertEqual(model.rows.map(\.id), ["b"])
        XCTAssertEqual(model.focused, "b")
    }

    func testEqualSizedDataReplacementAndFilterChangeInvalidatePendingWork() async throws {
        let model = BrowseModel()
        let gate = Gate()
        defer { gate.cancelAll() }
        model.filterRows = { try await gate.filter($0) }
        let a = try listing("a"), b = try listing("b", city: "Utrecht")
        model.listings.listings = [a]
        model.searchText = "Campus"
        let old = Task { await model.updateRows(debounce: false) }
        await waitUntil { gate.inputs.count == 1 }
        model.listings.listings = [b]
        model.query.cities = ["Utrecht"]
        gate.finish(0, rows: [a])
        await old.value
        XCTAssertTrue(model.isFiltering)
        XCTAssertTrue(model.rows.isEmpty)
        model.filterRows = BrowseModel.filter
        await model.updateRows(debounce: false)
        XCTAssertEqual(model.rows.map(\.id), ["b"])
    }

    func testClearingSearchRejectsLateResponseAndCancelledTaskNeverPublishes() async throws {
        let model = BrowseModel()
        let gate = Gate()
        defer { gate.cancelAll() }
        model.filterRows = { try await gate.filter($0) }
        let all = [try listing("a"), try listing("b")]
        model.listings.listings = all
        model.searchText = "a"
        let old = Task { await model.updateRows(debounce: false) }
        await waitUntil { gate.inputs.count == 1 }
        old.cancel()
        gate.finish(0, rows: [all[0]])
        await old.value
        XCTAssertTrue(model.isFiltering)
        XCTAssertTrue(model.rows.isEmpty)
        model.clearFilters()
        await model.updateRows(debounce: false)
        XCTAssertFalse(model.isFiltering)
        XCTAssertEqual(model.rows.map(\.id), ["a", "b"])
    }

    func testMatchingStillIncludesCityBuildingAndCaseInsensitiveName() async throws {
        let model = BrowseModel()
        model.listings.listings = [try listing("a", name: "Kastanjelaan 1"), try listing("b", city: "Utrecht")]
        for (text, expected) in [("KASTANJE", ["a"]), ("utrecht", ["b"]), ("  campus  ", ["a", "b"]), ("nothing", [])] {
            model.searchText = text
            await model.updateRows(debounce: false)
            XCTAssertEqual(model.rows.map(\.id), expected)
            XCTAssertFalse(model.isFiltering)
        }
    }
}
