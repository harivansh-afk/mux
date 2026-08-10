import Foundation

// Pure-data BSP split tree. Lean reimplementation of the model in ghostty's
// SplitTree.swift (MIT): leaves are pane IDs, splits carry direction+ratio.
// Codable by synthesis, so layout persistence is free.

enum SplitDirection: String, Codable {
    /// Side by side (split created by "split right").
    case horizontal
    /// Stacked (split created by "split down").
    case vertical
}

enum FocusDirection {
    case left, right, up, down
}

indirect enum SplitNode: Codable {
    case leaf(UUID)
    case split(SplitBranch)
}

struct SplitBranch: Codable {
    var direction: SplitDirection
    /// Fraction of space given to `first` (left/top). Clamped to [0.1, 0.9].
    var ratio: Double
    var first: SplitNode
    var second: SplitNode
}

extension SplitNode {
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

    /// Compute leaf rects within `bounds` (top-left origin assumed by the
    /// flipped container view). `gap` is inserted between siblings.
    func layout(in bounds: CGRect, gap: CGFloat = 1.0) -> [UUID: CGRect] {
        switch self {
        case let .leaf(id):
            return [id: bounds]
        case let .split(b):
            var firstRect = bounds
            var secondRect = bounds
            switch b.direction {
            case .horizontal:
                let w = (bounds.width - gap) * CGFloat(b.ratio)
                firstRect.size.width = w
                secondRect.origin.x = bounds.minX + w + gap
                secondRect.size.width = bounds.width - w - gap
            case .vertical:
                let h = (bounds.height - gap) * CGFloat(b.ratio)
                firstRect.size.height = h
                secondRect.origin.y = bounds.minY + h + gap
                secondRect.size.height = bounds.height - h - gap
            }
            var result = b.first.layout(in: firstRect, gap: gap)
            result.merge(b.second.layout(in: secondRect, gap: gap)) { a, _ in a }
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
        var best: (UUID, CGFloat)? = nil
        for (candidate, rect) in rects where candidate != id {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let eligible: Bool = switch direction {
            case .left: c.x < center.x - 1
            case .right: c.x > center.x + 1
            case .up: c.y < center.y - 1
            case .down: c.y > center.y + 1
            }
            guard eligible else { continue }
            let dx = c.x - center.x, dy = c.y - center.y
            let dist = dx * dx + dy * dy
            if best == nil || dist < best!.1 {
                best = (candidate, dist)
            }
        }
        return best?.0
    }

    /// Adjust the ratio of the deepest ancestor split of `id` whose
    /// direction matches `axis`. `delta` is signed toward first-child growth.
    /// Returns the adjusted tree and whether a split was found.
    func adjustingRatio(
        around id: UUID,
        axis: SplitDirection,
        delta: Double
    ) -> (SplitNode, Bool) {
        switch self {
        case .leaf:
            return (self, false)
        case var .split(b):
            // Depth-first: prefer the deepest matching split containing id.
            if b.first.contains(id) {
                let (adjusted, found) = b.first.adjustingRatio(around: id, axis: axis, delta: delta)
                if found {
                    b.first = adjusted
                    return (.split(b), true)
                }
                if b.direction == axis {
                    b.ratio = min(0.9, max(0.1, b.ratio + delta))
                    return (.split(b), true)
                }
                return (.split(b), false)
            }
            if b.second.contains(id) {
                let (adjusted, found) = b.second.adjustingRatio(around: id, axis: axis, delta: delta)
                if found {
                    b.second = adjusted
                    return (.split(b), true)
                }
                if b.direction == axis {
                    // Growing the second child means shrinking first.
                    b.ratio = min(0.9, max(0.1, b.ratio - delta))
                    return (.split(b), true)
                }
                return (.split(b), false)
            }
            return (self, false)
        }
    }
}
