import CoreGraphics

/// Lays out a collection's covers whole — never cropped — in the space its
/// card gives them, aiming for Apple Books' collection look.
///
/// Two families of arrangement are tried for the first few covers, each
/// sized from the covers' real proportions:
///
/// - **Feature**: Apple's own. The first cover large on the leading side at
///   full height, then columns of two (or, last, one) smaller covers whose
///   stacked height matches it exactly. Columns are sized to fit inside the
///   space — never run off the edge, since that would crop.
/// - **Rows**: covers in up to three rows, each row's covers sharing one
///   height and together spanning the full width. What suits sets of wide
///   covers (slides, scans) that a feature layout would shrink.
///
/// Every candidate is scored on how much of the space its covers fill, plus
/// a small bonus per cover shown, plus a bonus for the feature arrangement
/// when its feature cover is book-shaped — so ordinary books get the Apple
/// look and slide decks get rows. Arrangements with a cover too small to
/// read are rejected.
enum CollectionMosaic {
    /// At most this many covers are considered.
    static let maxCovers = 6

    private static let maxRows = 3
    private static let maxColumns = 3
    /// No cover shorter than this share of the space.
    private static let minHeightShare: CGFloat = 0.24
    private static let perCoverBonus: CGFloat = 0.04
    /// How strongly the Apple arrangement is preferred when it suits.
    private static let featureBonus: CGFloat = 0.25
    /// A collection shows at least this many covers (or all it has) when
    /// any such arrangement fits; fewer only as a fallback.
    private static let preferredMinimumCovers = 3
    /// A feature cover wider than this (relative to its height) is not
    /// book-shaped, and gets no feature bonus.
    private static let bookShapedLimit: CGFloat = 0.9

    /// Where each cover goes, in cover order, within `size` — the whole
    /// arrangement's bounding box, for the caller to place in the space.
    struct Arrangement: Equatable {
        var frames: [CGRect]
        var size: CGSize
    }

    static func layout(aspects: [CGFloat], in space: CGSize, gap: CGFloat) -> Arrangement? {
        guard space.width > 0, space.height > 0 else { return nil }
        let aspects = Array(aspects.prefix(maxCovers))
        guard !aspects.isEmpty, aspects.allSatisfy({ $0 > 0 }) else { return nil }

        var best: (score: CGFloat, arrangement: Arrangement)?
        func consider(_ arrangement: Arrangement?, bonus: CGFloat = 0) {
            guard let arrangement, !arrangement.frames.isEmpty else { return }
            let count = arrangement.frames.count
            let smallest = arrangement.frames.map(\.height).min() ?? 0
            if count > 1, smallest < space.height * minHeightShare { return }
            let covered = arrangement.frames.reduce(0) { $0 + $1.width * $1.height }
            let score = covered / (space.width * space.height)
                + perCoverBonus * CGFloat(count)
                + bonus
            if best == nil || score > best!.score {
                best = (score, arrangement)
            }
        }

        func tryCounts(_ counts: ClosedRange<Int>) {
            for count in counts {
                let chosen = Array(aspects.prefix(count))
                for rows in rowSplits(of: chosen) {
                    consider(rowsArrangement(rows, in: space, gap: gap))
                }
                if count > 1 {
                    let bonus = chosen[0] <= bookShapedLimit ? featureBonus : 0
                    consider(featureArrangement(chosen, in: space, gap: gap), bonus: bonus)
                }
            }
        }
        let minimum = min(aspects.count, preferredMinimumCovers)
        tryCounts(minimum...aspects.count)
        if best == nil, minimum > 1 { tryCounts(1...(minimum - 1)) }
        return best?.arrangement
    }

    // MARK: - Rows

    /// Every way to cut `aspects`, in order, into up to `maxRows` rows.
    private static func rowSplits(of aspects: [CGFloat]) -> [[[CGFloat]]] {
        var result: [[[CGFloat]]] = []
        // Bit i set: a new row starts after cover i.
        for breaks in 0..<(1 << (aspects.count - 1)) {
            var rows: [[CGFloat]] = [[]]
            for index in aspects.indices {
                rows[rows.count - 1].append(aspects[index])
                if index < aspects.count - 1, breaks & (1 << index) != 0 { rows.append([]) }
            }
            if rows.count <= maxRows { result.append(rows) }
        }
        return result
    }

    /// Each row at the height that makes it exactly full-width, then the
    /// whole stack scaled down (never up) to fit the height; rows centred.
    private static func rowsArrangement(_ rows: [[CGFloat]], in space: CGSize, gap: CGFloat) -> Arrangement? {
        let heights = rows.map { row in
            (space.width - gap * CGFloat(row.count - 1)) / row.reduce(0, +)
        }
        let available = space.height - gap * CGFloat(rows.count - 1)
        guard available > 0, heights.allSatisfy({ $0 > 0 }) else { return nil }
        let scale = min(1, available / heights.reduce(0, +))

        var frames: [CGRect] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        let rowWidths = zip(rows, heights).map { row, height in
            row.reduce(0) { $0 + $1 * height * scale } + gap * CGFloat(row.count - 1)
        }
        let boxWidth = rowWidths.max() ?? 0
        for (index, row) in rows.enumerated() {
            let height = heights[index] * scale
            var x = (boxWidth - rowWidths[index]) / 2
            for aspect in row {
                frames.append(CGRect(x: x, y: y, width: aspect * height, height: height))
                x += aspect * height + gap
            }
            width = max(width, rowWidths[index])
            y += height + gap
        }
        return Arrangement(frames: frames, size: CGSize(width: width, height: y - gap))
    }

    // MARK: - Feature + columns

    /// The first cover as the feature, the rest in columns of two (the last
    /// column may hold one, drawn at the size it would have in a pair and
    /// sitting on the bottom edge). Everything shares one height `h`; the
    /// largest `h` that fits both the space's height and width is used.
    private static func featureArrangement(_ aspects: [CGFloat], in space: CGSize, gap: CGFloat) -> Arrangement? {
        let rest = Array(aspects.dropFirst())
        let columns = stride(from: 0, to: rest.count, by: 2).map { Array(rest[$0..<min($0 + 2, rest.count)]) }
        guard columns.count <= maxColumns else { return nil }

        // A column of covers with aspects a, b stacked with a gap is
        // (h - gap) / (1/a + 1/b) wide; a single cover is a * h wide. The
        // total width is linear in h, so the h that fills the width solves
        // directly.
        var slope = aspects[0]
        var constant = gap * CGFloat(columns.count)
        for column in columns {
            if column.count == 2 {
                let k = 1 / (1 / column[0] + 1 / column[1])
                slope += k
                constant -= gap * k
            } else {
                // Sized as half of a pair of itself: (h - gap) * a / 2.
                slope += column[0] / 2
                constant -= gap * column[0] / 2
            }
        }
        let widthFilling = (space.width - constant) / slope
        let height = min(space.height, widthFilling)
        guard height > gap * 2 else { return nil }

        var frames = [CGRect(x: 0, y: 0, width: aspects[0] * height, height: height)]
        var x = aspects[0] * height + gap
        for column in columns {
            if column.count == 2 {
                let width = (height - gap) / (1 / column[0] + 1 / column[1])
                let top = width / column[0]
                frames.append(CGRect(x: x, y: 0, width: width, height: top))
                frames.append(CGRect(x: x, y: top + gap, width: width, height: width / column[1]))
                x += width + gap
            } else {
                // A lone last cover, small, on the shared bottom edge.
                let coverHeight = (height - gap) / 2
                let width = column[0] * coverHeight
                frames.append(CGRect(x: x, y: height - coverHeight, width: width, height: coverHeight))
                x += width + gap
            }
        }
        return Arrangement(frames: frames, size: CGSize(width: x - gap, height: height))
    }
}
