import Foundation
import XCTest
@testable import ReplacementEngine

final class ProductionTargetProcessIdentityTests: XCTestCase {
    func testAppDriftFailsClosedEvenWhenWindowTargetRangeAndTextStillMatch() {
        let decision = ProductionTargetPolicy.revalidationDecision(
            appMatches: false,
            pidMatches: true,
            windowMatches: true,
            targetMatches: true,
            capturedRange: CFRange(location: 2, length: 4),
            currentRange: CFRange(location: 2, length: 4),
            capturedSelectedText: "same",
            currentSelectedText: "same"
        )

        guard case .notReplaced = decision else {
            return XCTFail("application drift must fail closed before mutation")
        }
    }

    func testPIDDriftFailsClosedEvenWhenAppWindowTargetRangeAndTextStillMatch() {
        let decision = ProductionTargetPolicy.revalidationDecision(
            appMatches: true,
            pidMatches: false,
            windowMatches: true,
            targetMatches: true,
            capturedRange: CFRange(location: 2, length: 4),
            currentRange: CFRange(location: 2, length: 4),
            capturedSelectedText: "same",
            currentSelectedText: "same"
        )

        guard case .notReplaced = decision else {
            return XCTFail("process drift must fail closed before mutation")
        }
    }
}
