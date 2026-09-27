import Foundation

// layouts.json in the app's state folder (plan §1): atomic writes, the previous copy kept as layouts.prev.json,
// and a file from a newer Window Organizer is never read as something else nor overwritten.

public enum LayoutStoreError: Error, Equatable, CustomStringConvertible {
    case newerSchema(Int)

    public var description: String {
        switch self {
        case .newerSchema(let n):
            return "layouts.json was made by a newer Window Organizer (schema \(n)); it is left untouched."
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
        return try JSONDecoder().decode(Layouts.self, from: data)
    }

    public func save(_ layouts: Layouts) throws {
        let fm = FileManager.default
        if try existing() != nil {
            if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
            try fm.copyItem(at: file, to: previous)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(layouts).write(to: file, options: .atomic)
    }

    /// The file's bytes, nil when there is none; throws when its schema is newer than this build knows.
    private func existing() throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        struct Head: Decodable { let schema: Int }
        let schema = try JSONDecoder().decode(Head.self, from: data).schema
        if schema > Layouts.currentSchema { throw LayoutStoreError.newerSchema(schema) }
        return data
    }
}
