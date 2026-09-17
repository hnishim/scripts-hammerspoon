import XCTest
@testable import ReplacementEngine

final class ProductionIdentityPolicyTests: XCTestCase {
    func testProductionDispatchRejectsStructuralIdentityEvenWhenFieldStateIsStable() {
        let structural = TargetRevalidationResult(
            decision: .replacementEligible,
            identity: .structural,
            fieldState: .stable,
            reason: "structural_identity_only"
        )

        XCTAssertFalse(ProductionReplacementEngine.mayDispatch(structural))
    }

    func testProductionDispatchAllowsExactIdentityWithStableFieldState() {
        let exact = TargetRevalidationResult(
            decision: .replacementEligible,
            identity: .exact,
            fieldState: .stable,
            reason: "exact_identity"
        )

        XCTAssertTrue(ProductionReplacementEngine.mayDispatch(exact))
    }
}
