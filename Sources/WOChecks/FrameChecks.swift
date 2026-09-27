import Foundation
import WindowOrganizerCore

let frameChecks: [(String, @Sendable () throws -> Void)] = [
    ("frame round-trips through JSON", {
        let f = Frame(x: 10, y: 20, width: 800, height: 600)
        let data = try JSONEncoder().encode(f)
        try expectEqual(try JSONDecoder().decode(Frame.self, from: data), f)
    }),
]
