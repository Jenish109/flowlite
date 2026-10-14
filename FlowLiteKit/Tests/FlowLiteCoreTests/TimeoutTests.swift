import Foundation
import Testing
@testable import FlowLiteCore

struct Boom: Error, Equatable {}

/// Blocks the current thread, ignoring task cancellation (simulates a hung synchronous call).
func blockThread(seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

@Suite struct TimeoutTests {
    @Test func returnsValueWhenFast() async throws {
        let value = try await withTimeout(seconds: 1) { 42 }
        #expect(value == 42)
    }

    @Test func throwsTimeoutWhenSlow() async {
        let start = ContinuousClock.now
        await #expect(throws: TimeoutError.self) {
            try await withTimeout(seconds: 0.05) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
        }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func returnsOnTimeoutEvenIfOperationIgnoresCancellation() async {
        let start = ContinuousClock.now
        await #expect(throws: TimeoutError.self) {
            try await withTimeout(seconds: 0.05) { () async throws -> Int in
                blockThread(seconds: 2)
                return 1
            }
        }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func cancellingTheCallerThrowsCancellationError() async {
        let task = Task {
            try await withTimeout(seconds: 5) { () async throws -> Int in
                blockThread(seconds: 2)
                return 1
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func propagatesOperationErrors() async {
        await #expect(throws: Boom.self) {
            try await withTimeout(seconds: 1) { () async throws -> Int in throw Boom() }
        }
    }
}
