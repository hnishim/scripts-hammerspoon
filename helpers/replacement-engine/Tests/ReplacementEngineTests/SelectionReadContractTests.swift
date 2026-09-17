import CoreGraphics
import Foundation
import XCTest
@testable import ReplacementEngine

final class SelectionReadContractTests: XCTestCase {
    func testDirectSelectedTextWinsWithoutCopyFallback() {
        var copyCalls = 0
        let result = SelectionReadContract.resolve(
            contextAvailable: true,
            secure: false,
            selectedText: "direct",
            selectedRange: CFRange(location: 0, length: 5),
            value: "range",
            isEditable: true,
            copyFallback: {
                copyCalls += 1
                return "copy"
            }
        )

        XCTAssertEqual(result.status, .selected)
        XCTAssertEqual(result.text, "direct")
        XCTAssertEqual(result.source, .axSelectedText)
        XCTAssertEqual(copyCalls, 0)
    }

    func testRangeValueRecoveryPrecedesCopyFallback() {
        var copyCalls = 0
        let value = "A😀targetZ"
        let nsRange = (value as NSString).range(of: "target")
        let result = SelectionReadContract.resolve(
            contextAvailable: true,
            secure: false,
            selectedText: nil,
            selectedRange: CFRange(location: nsRange.location, length: nsRange.length),
            value: value,
            isEditable: true,
            copyFallback: {
                copyCalls += 1
                return "copy"
            }
        )

        XCTAssertEqual(result.status, .selected)
        XCTAssertEqual(result.text, "target")
        XCTAssertEqual(result.source, .axRangeValue)
        XCTAssertEqual(copyCalls, 0)
    }

    func testCopyFallbackMapsToSelectedWithoutExposingClipboardImplementation() {
        var copyCalls = 0
        let result = SelectionReadContract.resolve(
            contextAvailable: true,
            secure: false,
            selectedText: nil,
            selectedRange: nil,
            value: nil,
            isEditable: false,
            copyFallback: {
                copyCalls += 1
                return "copied"
            }
        )

        XCTAssertEqual(result.status, .selected)
        XCTAssertEqual(result.text, "copied")
        XCTAssertEqual(result.source, .clipboardCopy)
        XCTAssertEqual(copyCalls, 1)
    }

    func testNoSelectionIsDistinctFromUnavailableContext() {
        var copyCalls = 0
        let none = SelectionReadContract.resolve(
            contextAvailable: true,
            secure: false,
            selectedText: nil,
            selectedRange: CFRange(location: 3, length: 0),
            value: "abc",
            isEditable: true,
            copyFallback: {
                copyCalls += 1
                return "must not be used"
            }
        )
        XCTAssertEqual(none.status, .none)
        XCTAssertNil(none.text)
        XCTAssertNil(none.source)
        XCTAssertEqual(copyCalls, 0)

        let unavailable = SelectionReadContract.resolve(
            contextAvailable: false,
            secure: false,
            selectedText: nil,
            selectedRange: nil,
            value: nil,
            isEditable: false,
            copyFallback: { "must not be used" }
        )
        XCTAssertEqual(unavailable.status, .unavailable)
        XCTAssertNil(unavailable.text)
        XCTAssertNil(unavailable.source)
    }

    func testCopyFailureMapsToErrorRatherThanNone() {
        enum FixtureError: Error { case copyFailed }

        let result = SelectionReadContract.resolve(
            contextAvailable: true,
            secure: false,
            selectedText: nil,
            selectedRange: nil,
            value: nil,
            isEditable: false,
            copyFallback: { throw FixtureError.copyFailed }
        )

        XCTAssertEqual(result.status, .error)
        XCTAssertNil(result.text)
        XCTAssertNil(result.source)
    }

    func testSecureContextIsUnavailableAndNeverCopies() {
        var copyCalls = 0
        let result = SelectionReadContract.resolve(
            contextAvailable: true,
            secure: true,
            selectedText: "secret",
            selectedRange: CFRange(location: 0, length: 6),
            value: "secret",
            isEditable: true,
            copyFallback: {
                copyCalls += 1
                return "must not be used"
            }
        )

        XCTAssertEqual(result.status, .unavailable)
        XCTAssertNil(result.text)
        XCTAssertEqual(copyCalls, 0)
    }
}
