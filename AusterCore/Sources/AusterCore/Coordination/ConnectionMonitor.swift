import Foundation
import Network

/// Reports whether the machine has a network path at all.
///
/// An accelerator, not a source of truth: the coordinator learns it is offline
/// from the engine's own `.connection` failures, and would recover on its own by
/// retrying. What this adds is *promptness* — knowing the moment Wi-Fi comes
/// back rather than at the end of the next backoff.
public protocol ConnectionMonitoring: Sendable {

    /// `true` when a network path exists. The first value is the current state.
    var isOnline: AsyncStream<Bool> { get }

    func start()
    func stop()
}

/// `NWPathMonitor` behind the protocol.
public final class ConnectionMonitor: ConnectionMonitoring, @unchecked Sendable {

    public let isOnline: AsyncStream<Bool>

    private let continuation: AsyncStream<Bool>.Continuation
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.auster.connection")

    public init() {
        (isOnline, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func start() {
        let continuation = continuation
        monitor.pathUpdateHandler = { path in
            continuation.yield(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
    }
}
