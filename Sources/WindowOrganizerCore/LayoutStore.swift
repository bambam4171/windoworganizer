import Foundation

public enum LayoutStoreError: Error, Equatable, CustomStringConvertible {
    case newerSchema(Int), unsupportedSchema(Int), invalidLayout
    public var description: String {
        switch self {
        case .newerSchema(let n): return "layouts.json was made by a newer Window Organizer (schema \(n)); it is left untouched."
        case .unsupportedSchema(let n): return "Unsupported layout format (schema \(n))."
        case .invalidLayout: return "The layout contains invalid geometry or duplicate app rules."
        }
    }
}

public struct LayoutStore: Sendable {
    public let file: URL
    public let previous: URL
    public init(directory: URL) {
        file = directory.appendingPathComponent("layouts.json")
        previous = directory.appendingPathComponent("layouts.prev.json")
    }
    public func load() throws -> Layouts {
        guard let data = try existing() else { return Layouts() }
        return try Self.decode(data)
    }
    public static func decode(_ data: Data) throws -> Layouts {
        struct Head: Decodable { let schema: Int }
        let schema = try JSONDecoder().decode(Head.self, from: data).schema
        if schema > Layouts.currentSchema { throw LayoutStoreError.newerSchema(schema) }
        let layouts = try JSONDecoder().decode(Layouts.self, from: data)
        try layouts.validate()
        return layouts
    }
    public func save(_ layouts: Layouts) throws {
        try layouts.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(layouts)
        let data = try existing()
        if let data { _ = try Self.decode(data) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A backup update is atomic too; an invalid current file never destroys the last good backup.
        if let data { try data.write(to: previous, options: .atomic) }
        try encoded.write(to: file, options: .atomic)
    }
    /// Restore the last good copy only after validation. Preserve a damaged current file for inspection.
    public func restorePrevious() throws {
        let backup = try Data(contentsOf: previous)
        let recovered = try Self.decode(backup)
        if FileManager.default.fileExists(atPath: file.path) {
            let current = try Data(contentsOf: file)
            do { _ = try Self.decode(current) }
            catch LayoutStoreError.newerSchema(let n) { throw LayoutStoreError.newerSchema(n) }
            catch { /* Explicit recovery can replace a corrupt current file. */ }
            try current.write(to: file.deletingLastPathComponent().appendingPathComponent("layouts.before-recovery-\(UUID().uuidString).json"), options: .atomic)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recovered).write(to: file, options: .atomic)
    }

    private func existing() throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        _ = try Self.decode(data)
        return data
    }
}
