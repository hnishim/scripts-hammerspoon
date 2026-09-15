import Foundation
import XCTest
@testable import ReplacementEngine

final class ProductionTargetCaptureIdentityTests: XCTestCase {
    func testCaptureRequiresApplicationBundleIdentity() {
        let decision = ProductionTargetPolicy.captureDecision(
            hasAppBundleID: false,
            hasPID: true,
            hasFocusedWindow: true,
            hasResolvedTarget: true,
            selectedRange: CFRange(location: 4, length: 3)
        )

        guard case .displayOnly = decision else {
            return XCTFail("missing application bundle identity must fail closed to display_only")
        }
    }

    func testCaptureRequiresProcessIdentity() {
        let decision = ProductionTargetPolicy.captureDecision(
            hasAppBundleID: true,
            hasPID: false,
            hasFocusedWindow: true,
            hasResolvedTarget: true,
            selectedRange: CFRange(location: 4, length: 3)
        )

        guard case .displayOnly = decision else {
            return XCTFail("missing process identity must fail closed to display_only")
        }
    }

    func testCaptureRequiresFocusedWindow() {
        let decision = ProductionTargetPolicy.captureDecision(
            hasAppBundleID: true,
            hasPID: true,
            hasFocusedWindow: false,
            hasResolvedTarget: true,
            selectedRange: CFRange(location: 4, length: 3)
        )

        guard case .displayOnly = decision else {
            return XCTFail("missing focused window must fail closed to display_only")
        }
    }

    func testCaptureRequiresResolvedTarget() {
        let decision = ProductionTargetPolicy.captureDecision(
            hasAppBundleID: true,
            hasPID: true,
            hasFocusedWindow: true,
            hasResolvedTarget: false,
            selectedRange: CFRange(location: 4, length: 3)
        )

        guard case .displayOnly = decision else {
            return XCTFail("missing resolved target must fail closed to display_only")
        }
    }

    func testCaptureRequiresPositiveSelectedRange() {
        let decision = ProductionTargetPolicy.captureDecision(
            hasAppBundleID: true,
            hasPID: true,
            hasFocusedWindow: true,
            hasResolvedTarget: true,
            selectedRange: CFRange(location: 4, length: 0)
        )

        guard case .displayOnly = decision else {
            return XCTFail("zero-length selected range must fail closed to display_only")
        }
    }

    func testRevalidationDoesNotRequireSelectedTextWhenStructuralIdentityMatches() {
        let decision = ProductionTargetPolicy.revalidationDecision(
            appMatches: true,
            pidMatches: true,
            windowMatches: true,
            targetMatches: true,
            capturedRange: CFRange(location: 2, length: 4),
            currentRange: CFRange(location: 2, length: 4),
            capturedSelectedText: nil,
            currentSelectedText: "now available"
        )

        XCTAssertEqual(
            decision,
            .replacementEligible,
            "selected text is optional evidence; matching structural identity must remain replacement-eligible"
        )
    }

    func testRevalidationDoesNotRequireSelectedTextWhenUnavailableAtBothPoints() {
        let decision = ProductionTargetPolicy.revalidationDecision(
            appMatches: true,
            pidMatches: true,
            windowMatches: true,
            targetMatches: true,
            capturedRange: CFRange(location: 2, length: 4),
            currentRange: CFRange(location: 2, length: 4),
            capturedSelectedText: nil,
            currentSelectedText: nil
        )

        XCTAssertEqual(
            decision,
            .replacementEligible,
            "selected text availability itself must remain optional when structural identity matches"
        )
    }
}
