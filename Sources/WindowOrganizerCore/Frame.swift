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

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
