import CoreGraphics

/// A window frame in global screen coordinates (top-left origin, as Accessibility reports it).
public struct Frame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var isValid: Bool { x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0 }

    /// Keep the entire window inside the usable screen area after a resolution change.
    public func contained(in area: Frame) -> Frame {
        guard isValid, area.isValid else { return area }
        let w = min(width, area.width), h = min(height, area.height)
        return Frame(x: min(max(x, area.x), area.x + area.width - w),
                     y: min(max(y, area.y), area.y + area.height - h), width: w, height: h)
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
