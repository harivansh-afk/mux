import Foundation
import XCTest

@testable import Tiling

final class SplitTreeTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)

    // MARK: - insert / remove

    func testInsertSplitsTheTargetLeaf() {
        let a = UUID(), b = UUID()
        let right = SplitNode.leaf(a).inserting(b, at: a, direction: .horizontal)
        XCTAssertEqual(right.leaves, [a, b])
        let left = SplitNode.leaf(a).inserting(b, at: a, direction: .horizontal, newFirst: true)
        XCTAssertEqual(left.leaves, [b, a])
    }

    func testInsertAtAMissingTargetChangesNothing() {
        let a = UUID()
        XCTAssertEqual(SplitNode.leaf(a).inserting(UUID(), at: UUID(), direction: .vertical).leaves, [a])
    }

    func testRemoveUndoesInsertAtEveryDepth() {
        let a = UUID(), b = UUID(), c = UUID()
        let pair = SplitNode.leaf(a).inserting(b, at: a, direction: .horizontal)
        let nested = pair.inserting(c, at: b, direction: .vertical)
        XCTAssertEqual(nested.leaves, [a, b, c])
        XCTAssertTrue(nested.contains(c))

        // Removing the leaf just added restores the tree it was added to.
        XCTAssertEqual(nested.removing(c)?.leaves, pair.leaves)
        XCTAssertEqual(pair.removing(b)?.leaves, [a])
        XCTAssertNil(SplitNode.leaf(a).removing(a))
    }

    func testRemovePromotesTheSiblingRatherThanKeepingAOneChildSplit() {
        let a = UUID(), b = UUID(), c = UUID()
        let nested = SplitNode.leaf(a)
            .inserting(b, at: a, direction: .horizontal)
            .inserting(c, at: b, direction: .vertical)
        guard case let .split(branch)? = nested.removing(c) else {
            return XCTFail("expected the outer split to survive")
        }
        XCTAssertEqual(branch.direction, .horizontal)
        XCTAssertEqual(branch.first.leaves, [a])
        XCTAssertEqual(branch.second.leaves, [b])
    }

    func testCodableRoundTripsTheTree() throws {
        let a = UUID(), b = UUID()
        let tree = SplitNode.leaf(a).inserting(b, at: a, direction: .vertical, ratio: 0.25)
        let decoded = try JSONDecoder().decode(SplitNode.self, from: JSONEncoder().encode(tree))
        XCTAssertEqual(decoded.leaves, tree.leaves)
        XCTAssertEqual(ratio(of: decoded), 0.25)
    }

    // MARK: - moving

    func testMovingAtAnEdgeIsNilWhenThePaneAlreadySpansIt() {
        let a = UUID(), b = UUID()
        // a | b, side by side: a already spans the left edge, b the right.
        let tree = SplitNode.leaf(a).inserting(b, at: a, direction: .horizontal)
        XCTAssertNil(tree.moving(a, direction: .left, in: bounds))
        XCTAssertNil(tree.moving(b, direction: .right, in: bounds))
    }

    func testMovingWithNoNeighborWrapsTheTree() {
        let a = UUID(), b = UUID()
        let tree = SplitNode.leaf(a).inserting(b, at: a, direction: .horizontal)
        // Nothing is below a, so a becomes the bottom half of a new root.
        guard case let .split(branch)? = tree.moving(a, direction: .down, in: bounds) else {
            return XCTFail("expected a wrapping split")
        }
        XCTAssertEqual(branch.direction, .vertical)
        XCTAssertEqual(branch.first.leaves, [b])
        XCTAssertEqual(branch.second.leaves, [a])
        // And once it spans that edge, the same move is a no-op.
        XCTAssertNil(SplitNode.split(branch).moving(a, direction: .down, in: bounds))
    }

    func testMovingTowardANeighborReordersThePanes() {
        let a = UUID(), b = UUID()
        let tree = SplitNode.leaf(a).inserting(b, at: a, direction: .horizontal)
        XCTAssertEqual(tree.moving(a, direction: .right, in: bounds)?.leaves, [b, a])
    }

    func testMovingTheSolePaneIsNil() {
        let a = UUID()
        XCTAssertNil(SplitNode.leaf(a).moving(a, direction: .left, in: bounds))
    }

    // MARK: - adjustingRatio

    func testAdjustingRatioAtTheClampFloorHoldsAndNeverFlipsSign() {
        let a = UUID(), b = UUID()
        let floored = SplitNode.leaf(a).inserting(b, at: a, direction: .horizontal, ratio: 0.1)
        // Shrinking the first child at the floor leaves the ratio alone;
        // it must never come back as growth.
        XCTAssertEqual(try XCTUnwrap(ratio(of: floored.adjustingRatio(
            around: a, axis: .horizontal, delta: -0.03
        ))), 0.1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(ratio(of: floored.adjustingRatio(
            around: a, axis: .horizontal, delta: 0.03
        ))), 0.13, accuracy: 1e-9)

        let ceiled = SplitNode.leaf(a).inserting(b, at: a, direction: .horizontal, ratio: 0.9)
        XCTAssertEqual(try XCTUnwrap(ratio(of: ceiled.adjustingRatio(
            around: a, axis: .horizontal, delta: 0.03
        ))), 0.9, accuracy: 1e-9)
    }

    func testShrinkingAtTheFloorNeverWidensThePane() {
        let a = UUID(), b = UUID()
        let tree = SplitNode.leaf(a).inserting(b, at: a, direction: .horizontal, ratio: 0.1)
        let before = try? XCTUnwrap(tree.layout(in: bounds)[a]).width
        let after = try? XCTUnwrap(
            (tree.adjustingRatio(around: a, axis: .horizontal, delta: -0.03) ?? tree)
                .layout(in: bounds)[a]
        ).width
        XCTAssertEqual(try XCTUnwrap(after), try XCTUnwrap(before), accuracy: 1e-9)
    }

    func testDeltaIsSignedTowardFirstChildGrowth() {
        let a = UUID(), b = UUID()
        let tree = SplitNode.leaf(a).inserting(b, at: a, direction: .horizontal, ratio: 0.5)
        // The same positive delta grows whichever child is asked about.
        XCTAssertEqual(try XCTUnwrap(ratio(of: tree.adjustingRatio(
            around: a, axis: .horizontal, delta: 0.03
        ))), 0.53, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(ratio(of: tree.adjustingRatio(
            around: b, axis: .horizontal, delta: 0.03
        ))), 0.47, accuracy: 1e-9)
    }

    func testAdjustingRatioIsNilWithoutAMatchingAncestor() {
        let a = UUID(), b = UUID()
        let tree = SplitNode.leaf(a).inserting(b, at: a, direction: .horizontal)
        XCTAssertNil(tree.adjustingRatio(around: a, axis: .vertical, delta: 0.03))
        XCTAssertNil(tree.adjustingRatio(around: UUID(), axis: .horizontal, delta: 0.03))
        XCTAssertNil(SplitNode.leaf(a).adjustingRatio(around: a, axis: .horizontal, delta: 0.03))
    }

    func testAdjustingRatioPrefersTheDeepestMatchingSplit() {
        let a = UUID(), b = UUID(), c = UUID()
        // (a | b) stacked over nothing: an inner horizontal split inside an
        // outer horizontal one.
        let tree = SplitNode.leaf(a)
            .inserting(c, at: a, direction: .horizontal, ratio: 0.5)
            .inserting(b, at: a, direction: .horizontal, ratio: 0.5)
        guard case let .split(outer)? = tree.adjustingRatio(
            around: a, axis: .horizontal, delta: 0.03
        ) else { return XCTFail("expected an adjusted split") }
        XCTAssertEqual(outer.ratio, 0.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(ratio(of: outer.first)), 0.53, accuracy: 1e-9)
    }

    // MARK: - neighbor

    func testNeighborPicksTheNearestCentre() {
        let a = UUID(), near = UUID(), far = UUID(), left = UUID()
        let rects: [UUID: CGRect] = [
            a: CGRect(x: 100, y: 100, width: 20, height: 20),
            near: CGRect(x: 140, y: 100, width: 20, height: 20),
            far: CGRect(x: 400, y: 100, width: 20, height: 20),
            left: CGRect(x: 0, y: 100, width: 20, height: 20),
        ]
        XCTAssertEqual(SplitNode.neighbor(of: a, direction: .right, rects: rects), near)
        XCTAssertEqual(SplitNode.neighbor(of: a, direction: .left, rects: rects), left)
        XCTAssertNil(SplitNode.neighbor(of: a, direction: .up, rects: rects))
        XCTAssertNil(SplitNode.neighbor(of: a, direction: .down, rects: rects))
        XCTAssertNil(SplitNode.neighbor(of: UUID(), direction: .right, rects: rects))
        XCTAssertNotEqual(SplitNode.neighbor(of: a, direction: .right, rects: rects), far)
    }

    func testNeighborBreaksAnAxisTieOnThePerpendicularDistance() {
        let a = UUID(), aligned = UUID(), offset = UUID()
        let rects: [UUID: CGRect] = [
            a: CGRect(x: 100, y: 100, width: 20, height: 20),
            aligned: CGRect(x: 140, y: 100, width: 20, height: 20),
            offset: CGRect(x: 140, y: 400, width: 20, height: 20),
        ]
        XCTAssertEqual(SplitNode.neighbor(of: a, direction: .right, rects: rects), aligned)
        XCTAssertEqual(SplitNode.neighbor(of: a, direction: .down, rects: rects), offset)
    }

    // MARK: - helper

    private func ratio(of node: SplitNode?) -> Double? {
        guard case let .split(branch)? = node else { return nil }
        return branch.ratio
    }
}
