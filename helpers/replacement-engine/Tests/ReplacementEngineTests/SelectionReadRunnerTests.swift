import CoreGraphics
import Foundation
import XCTest
@testable import ReplacementEngine

final class SelectionReadRunnerTests: XCTestCase {
    func testProductionReadRunnerEmitsOneSelectedProtocolEvent() throws {
        let result = SelectionReadContract.resolve(
            contextAvailable: true,
            secure: false,
            selectedText: "selected",
            selectedRange: CFRange(location: 0, length: 8),
            value: "selected",
            isEditable: true,
            copyFallback: { "unused" }
        )
        var emitted: [[String: Any]] = []

        let runner = ProductionSelectionReadRunner(
            capture: { result },
            emit: { event in
                let data = try! JSONEncoder().encode(event)
                let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
                emitted.append(object)
            }
        )

        try runner.run()

        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted[0]["event"] as? String, "read")
        XCTAssertEqual(emitted[0]["status"] as? String, "selected")
        XCTAssertEqual(emitted[0]["text"] as? String, "selected")
        XCTAssertEqual(emitted[0]["source"] as? String, "ax_selected_text")
        XCTAssertNil(emitted[0]["replacement_eligible"])
        XCTAssertNil(emitted[0]["outcome"])
    }

    func testProductionReadRunnerPreservesNoneUnavailableAndErrorStatuses() throws {
        let none = SelectionReadContract.resolve(
            contextAvailable: true,
            secure: false,
            selectedText: nil,
            selectedRange: CFRange(location: 3, length: 0),
            value: "abc",
            isEditable: true,
            copyFallback: { "unused" }
        )
        var noneEvent: [String: Any]?
        try ProductionSelectionReadRunner(
            capture: { none },
            emit: { event in
                let data = try! JSONEncoder().encode(event)
                noneEvent = try! JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
        ).run()
        XCTAssertEqual(noneEvent?["event"] as? String, "read")
        XCTAssertEqual(noneEvent?["status"] as? String, "none")
        XCTAssertNil(noneEvent?["text"])
        XCTAssertNil(noneEvent?["source"])

        let unavailable = SelectionReadContract.resolve(
            contextAvailable: false,
            secure: false,
            selectedText: nil,
            selectedRange: nil,
            value: nil,
            isEditable: false,
            copyFallback: { "unused" }
        )
        var unavailableEvent: [String: Any]?
        try ProductionSelectionReadRunner(
            capture: { unavailable },
            emit: { event in
                let data = try! JSONEncoder().encode(event)
                unavailableEvent = try! JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
        ).run()
        XCTAssertEqual(unavailableEvent?["status"] as? String, "unavailable")
        XCTAssertNil(unavailableEvent?["text"])
        XCTAssertNil(unavailableEvent?["source"])

        enum FixtureError: Error { case copyFailed }
        let error = SelectionReadContract.resolve(
            contextAvailable: true,
            secure: false,
            selectedText: nil,
            selectedRange: nil,
            value: nil,
            isEditable: false,
            copyFallback: { throw FixtureError.copyFailed }
        )
        var errorEvent: [String: Any]?
        try ProductionSelectionReadRunner(
            capture: { error },
            emit: { event in
                let data = try! JSONEncoder().encode(event)
                errorEvent = try! JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
        ).run()
        XCTAssertEqual(errorEvent?["status"] as? String, "error")
        XCTAssertNil(errorEvent?["text"])
        XCTAssertNil(errorEvent?["source"])
    }
}
