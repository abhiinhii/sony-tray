import Foundation

/// A ~60-line stand-in for XCTest.
///
/// XCTest.framework ships only with full Xcode, and this port is meant to stay buildable with
/// nothing but the Command Line Tools (see macos/README.md). Each `test(...)` call is one test
/// case, so a `[Theory]` in the C# suite becomes one `test(...)` per `InlineData` row and the
/// totals stay directly comparable.
enum Harness {
    static var passed = 0
    static var failed = 0
    fileprivate static var currentFailures: [String] = []

    static func summary() -> Int32 {
        let total = passed + failed
        if failed == 0 {
            print("\n\(total) tests passed.")
            return 0
        }
        print("\n\(failed) of \(total) tests FAILED.")
        return 1
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    Harness.currentFailures = []
    do {
        try body()
    } catch HarnessStop.unwrapFailed {
        // expectNotNil already recorded the failure; it throws only to stop the body.
    } catch {
        Harness.currentFailures.append("threw unexpected error: \(error)")
    }
    if Harness.currentFailures.isEmpty {
        Harness.passed += 1
    } else {
        Harness.failed += 1
        print("  ✗ \(name)")
        for failure in Harness.currentFailures { print("      \(failure)") }
    }
}

func record(_ message: String, _ line: UInt) {
    Harness.currentFailures.append("line \(line): \(message)")
}

func hex(_ bytes: [UInt8]) -> String {
    "[" + bytes.map { String(format: "%02X", $0) }.joined(separator: " ") + "]"
}

// More specific than the generic overload below, so byte arrays report as readable hex.
func expectEqual(_ actual: [UInt8], _ expected: [UInt8], line: UInt = #line) {
    if actual != expected { record("expected \(hex(expected)), got \(hex(actual))", line) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, line: UInt = #line) {
    if actual != expected { record("expected \(expected), got \(actual)", line) }
}

func expectTrue(_ value: Bool, _ label: String = "", line: UInt = #line) {
    if !value { record("expected true\(label.isEmpty ? "" : " (\(label))")", line) }
}

func expectFalse(_ value: Bool, _ label: String = "", line: UInt = #line) {
    if value { record("expected false\(label.isEmpty ? "" : " (\(label))")", line) }
}

func expectNil<T>(_ value: T?, _ label: String = "", line: UInt = #line) {
    if let value { record("expected nil\(label.isEmpty ? "" : " (\(label))"), got \(value)", line) }
}

/// Mirrors `XCTUnwrap`: records a failure and throws so the test body stops.
func expectNotNil<T>(_ value: T?, _ label: String = "", line: UInt = #line) throws -> T {
    guard let value else {
        record("expected non-nil\(label.isEmpty ? "" : " (\(label))")", line)
        throw HarnessStop.unwrapFailed
    }
    return value
}

func expectThrows(_ body: () throws -> Void, line: UInt = #line) {
    do {
        try body()
        record("expected an error to be thrown", line)
    } catch {
        // expected
    }
}

func fail(_ message: String, line: UInt = #line) {
    record(message, line)
}

enum HarnessStop: Error { case unwrapFailed }
