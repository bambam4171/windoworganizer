import Foundation

/// What the screens and desktops look like at one moment. Every action reads it before it plans and checks it again
/// before it writes or keeps moving; a difference means the user switched desktop or screen meanwhile.
public struct WorkspaceContext: Equatable, Sendable {
    public var screens: [ScreenInfo]
    public var counts: [String: Int]
    public var desktops: [String: Int]
    public var identities: [DisplaySpaces]

    public init(screens: [ScreenInfo], counts: [String: Int], desktops: [String: Int], identities: [DisplaySpaces] = []) {
        self.screens = screens; self.counts = counts; self.desktops = desktops; self.identities = identities
    }

    /// False when macOS gave no desktop identities (a fullscreen Space): desktops are then all 0 and nothing may be saved for them.
    public var isIdentified: Bool { !identities.isEmpty }
}
