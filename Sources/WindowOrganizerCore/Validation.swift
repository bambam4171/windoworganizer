import Foundation

extension Layouts {
    /// Reject malformed imported or hand-edited geometry before it can move any window.
    public func validate() throws {
        guard schema == Self.currentSchema else { throw LayoutStoreError.unsupportedSchema(schema) }
        func require(_ good: Bool) throws { if !good { throw LayoutStoreError.invalidLayout } }
        for desktops in setups.values {
            for (desktop, screens) in desktops {
                try require(Int(desktop).map { $0 >= 0 && $0 <= 1000 } ?? false)
                for (screen, arrangement) in screens {
                    try require(!screen.isEmpty)
                    switch arrangement.kind {
                    case .snapshot(let places):
                        for p in places {
                            try require(!p.matcher.bundleID.isEmpty && p.matcher.order >= 0 && p.pixel.isValid && p.visibleFrame.isValid && p.fraction.isValid && p.screenUUID == screen)
                        }
                    case .zones(let zones):
                        for z in zones {
                            try require(z.rect.isWithinUnit && z.members.allSatisfy { !$0.bundleID.isEmpty })
                        }
                    case .autoTile: break
                    }
                }
            }
        }
        for (desktop, screens) in arrange {
            try require(Int(desktop).map { $0 >= 0 && $0 <= 1000 } ?? false)
            for (screen, settings) in screens { try require(!screen.isEmpty && (0...ArrangeSettings.maxGap).contains(settings.gapPoints)) }
        }
        try require(Set(rules.map(\.bundleID)).count == rules.count)
        for rule in rules { try require(!rule.bundleID.isEmpty && !rule.screen.isEmpty && rule.desktop >= 0 && rule.desktop <= 1000 && rule.area.isWithinUnit) }
    }
}

/// A compact grid for all windows of a screen, with shared rounded edges and no empty cells in the last row.
public func gridTile(_ n: Int, in area: Frame) -> [Frame] {
    guard n > 0, area.isValid else { return [] }
    let columns = min(n, max(1, Int(ceil(sqrt(Double(n) * area.width / area.height)))))
    let rows = Int(ceil(Double(n) / Double(columns)))
    var frames: [Frame] = []
    for row in 0..<rows {
        let count = min(columns, n - row * columns)
        let y0 = (area.y + Double(row) * area.height / Double(rows)).rounded()
        let y1 = (area.y + Double(row + 1) * area.height / Double(rows)).rounded()
        for col in 0..<count {
            let x0 = (area.x + Double(col) * area.width / Double(count)).rounded()
            let x1 = (area.x + Double(col + 1) * area.width / Double(count)).rounded()
            frames.append(Frame(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        }
    }
    return frames
}
