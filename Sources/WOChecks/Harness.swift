import Foundation

/// Minimal test harness: each check throws on failure; the run prints one line per check and a summary.
struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line) throws {
    if !condition { throw CheckFailure(description: "\(file):\(line): \(message())") }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #fileID, line: UInt = #line) throws {
    try expect(a == b, "\(a) != \(b)", file: file, line: line)
}

func runChecks(_ checks: [(String, @Sendable () throws -> Void)]) -> Int32 {
    var failed = 0
    for (name, body) in checks {
        do { try body(); print("ok    \(name)") }
        catch { failed += 1; print("FAIL  \(name): \(error)") }
    }
    print("\(checks.count - failed) passed / \(failed) failed")
    return failed == 0 ? 0 : 1
}
