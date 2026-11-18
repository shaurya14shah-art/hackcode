import Foundation

/// Delivers streamed text chunks to the main actor strictly in arrival order.
/// (Spawning one `Task { @MainActor in … }` per chunk does not guarantee ordering.)
@MainActor
final class OrderedTextStream {
    let onDelta: @Sendable (String) -> Void
    private let continuation: AsyncStream<String>.Continuation
    private let consumer: Task<Void, Never>

    init(_ append: @escaping @MainActor (String) -> Void) {
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        self.onDelta = { continuation.yield($0) }
        self.consumer = Task { @MainActor in
            for await chunk in stream { append(chunk) }
        }
    }

    /// Call after the producer finished; waits until every chunk has been appended.
    func finish() async {
        continuation.finish()
        await consumer.value
    }
}
