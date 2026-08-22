import Foundation

// Foundation alone gives the bare CGRect struct; the geometry accessors this
// file uses come from CoreGraphics on Apple platforms and from Foundation
// itself elsewhere.
#if canImport(CoreGraphics)
    import CoreGraphics
#endif

// Pure-data BSP split tree. Lean reimplementation of the model in ghostty's
// SplitTree.swift (MIT): leaves are pane IDs, splits carry direction+ratio.
// Codable by synthesis, so layout persistence is free.
//
// Its own target because it is the one part of the app that depends on
// nothing but Foundation, so `swift test` can reach it without AppKit or
// the GhosttyKit xcframework.

public enum SplitDirection: String, Codable {
    /// Side by side (split created by "split right").
    case horizontal
    /// Stacked (split created by "split down").
    case vertical
}

public enum FocusDirection {
    case left, right, up, down
}

public indirect enum SplitNode: Codable {
    case leaf(UUID)
    case split(SplitBranch)
}

public struct SplitBranch: Codable {
    public var direction: SplitDirection
    /// Fraction of space given to `first` (left/top). Clamped to [0.1, 0.9].
    public var ratio: Double
    public var first: SplitNode
    public var second: SplitNode
}

public extension SplitNode {
    var leaves: [UUID] {
        switch self {
        case let .leaf(id): [id]
        case let .split(b): b.first.leaves + b.second.leaves
        }
    }

    func contains(_ id: UUID) -> Bool {
        switch self {
        case let .leaf(l): l == id
        case let .split(b): b.first.contains(id) || b.second.contains(id)
        }
    }

    /// Replace the leaf `target` with a split of (target, newLeaf).
    /// `newFirst` puts the new leaf on the left/top side.
    func inserting(
        _ newLeaf: UUID,
        at target: UUID,
        direction: SplitDirection,
        ratio: Double = 0.5,
        newFirst: Bool = false
    ) -> SplitNode {
        switch self {
        case let .leaf(id) where id == target:
            let old = SplitNode.leaf(id)
            let new = SplitNode.leaf(newLeaf)
            return .split(SplitBranch(
                direction: direction,
                ratio: ratio,
                first: newFirst ? new : old,
                second: newFirst ? old : new
            ))
        case .leaf:
            return self
        case var .split(b):
            b.first = b.first.inserting(newLeaf, at: target, direction: direction, ratio: ratio, newFirst: newFirst)
            b.second = b.second.inserting(newLeaf, at: target, direction: direction, ratio: ratio, newFirst: newFirst)
            return .split(b)
        }
    }

    /// Remove a leaf; the sibling is promoted. Returns nil if the tree
    /// becomes empty.
    func removing(_ target: UUID) -> SplitNode? {
        switch self {
        case let .leaf(id):
            return id == target ? nil : self
        case var .split(b):
            let first = b.first.removing(target)
            let second = b.second.removing(target)
            switch (first, second) {
            case (nil, nil): return nil
            case (nil, let s?): return s
            case (let f?, nil): return f
            case let (f?, s?):
                b.first = f
                b.second = s
                return .split(b)
            }
        }
    }

    /// One point between siblings: the divider the container paints into.
    private static let gap: CGFloat = 1

    /// Compute leaf rects within `bounds` (top-left origin assumed by the
    /// flipped container view).
    func layout(in bounds: CGRect) -> [UUID: CGRect] {
        switch self {
        case let .leaf(id):
            return [id: bounds]
        case let .split(b):
            var firstRect = bounds
            var secondRect = bounds
            switch b.direction {
            case .horizontal:
                let w = (bounds.width - Self.gap) * CGFloat(b.ratio)
                firstRect.size.width = w
                secondRect.origin.x = bounds.minX + w + Self.gap
                secondRect.size.width = bounds.width - w - Self.gap
            case .vertical:
                let h = (bounds.height - Self.gap) * CGFloat(b.ratio)
                firstRect.size.height = h
                secondRect.origin.y = bounds.minY + h + Self.gap
                secondRect.size.height = bounds.height - h - Self.gap
            }
            var result = b.first.layout(in: firstRect)
            result.merge(b.second.layout(in: secondRect)) { a, _ in a }
            return result
        }
    }

    /// Spatially nearest leaf in a direction, from computed rects.
    /// tmux-style edge fallback is applied by the caller.
    static func neighbor(
        of id: UUID,
        direction: FocusDirection,
        rects: [UUID: CGRect]
    ) -> UUID? {
        guard let from = rects[id] else { return nil }
        let center = CGPoint(x: from.midX, y: from.midY)
        func eligible(_ rect: CGRect) -> Bool {
            switch direction {
            case .left: rect.midX < center.x - 1
            case .right: rect.midX > center.x + 1
            case .up: rect.midY < center.y - 1
            case .down: rect.midY > center.y + 1
            }
        }
        func distance(_ rect: CGRect) -> CGFloat {
            let dx = rect.midX - center.x, dy = rect.midY - center.y
            return dx * dx + dy * dy
        }
        return rects
            .filter { $0.key != id && eligible($0.value) }
            .min { distance($0.value) < distance($1.value) }?
            .key
    }

    /// Move a leaf one step in a direction: it re-enters the tree beside
    /// its spatial neighbor on that side (splitting the neighbor along the
    /// move axis); with no neighbor it wraps the whole tree instead, so the
    /// pane spans that edge. Returns nil when the move is a no-op (sole
    /// pane, or already spanning that edge).
    func moving(_ id: UUID, direction: FocusDirection, in bounds: CGRect) -> SplitNode? {
        guard contains(id), let rest = removing(id) else { return nil }
        let axis: SplitDirection = (direction == .left || direction == .right)
            ? .horizontal : .vertical
        let toFirst = (direction == .left || direction == .up)
        if let neighbor = Self.neighbor(of: id, direction: direction, rects: layout(in: bounds)) {
            return rest.inserting(id, at: neighbor, direction: axis, newFirst: toFirst)
        }
        // At the edge: the pane becomes one side of a new root split -
        // unless it already is, when the move would only reset the ratio.
        if case let .split(b) = self, b.direction == axis,
           case let .leaf(edge) = toFirst ? b.first : b.second, edge == id {
            return nil
        }
        let pane = SplitNode.leaf(id)
        return .split(SplitBranch(
            direction: axis,
            ratio: 0.5,
            first: toFirst ? pane : rest,
            second: toFirst ? rest : pane
        ))
    }

    /// Adjust the ratio of the deepest ancestor split of `id` whose
    /// direction matches `axis`. `delta` is signed toward first-child growth.
    /// Returns nil when `id` has no such ancestor.
    func adjustingRatio(
        around id: UUID,
        axis: SplitDirection,
        delta: Double
    ) -> SplitNode? {
        guard case var .split(b) = self else { return nil }
        for (isFirst, child) in [(true, b.first), (false, b.second)] where child.contains(id) {
            // Depth-first: prefer the deepest matching split containing id.
            if let adjusted = child.adjustingRatio(around: id, axis: axis, delta: delta) {
                if isFirst { b.first = adjusted } else { b.second = adjusted }
                return .split(b)
            }
            guard b.direction == axis else { return nil }
            // Growing the second child means shrinking the first.
            b.ratio = min(0.9, max(0.1, b.ratio + (isFirst ? delta : -delta)))
            return .split(b)
        }
        return nil
    }
}
