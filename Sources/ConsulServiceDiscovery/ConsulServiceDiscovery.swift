import Dispatch
import ServiceDiscovery

public final class ConsulServiceDiscovery: ServiceDiscovery, Sendable {
    public typealias Service = String
    public typealias Instance = NodeService

    private let consul: Consul

    public init(_ consul: Consul) {
        self.consul = consul
    }

    public let defaultLookupTimeout: DispatchTimeInterval = .seconds(1)

    public func lookup(_ service: Service, deadline _: DispatchTime?, callback: @escaping @Sendable (Result<[Instance], Error>) -> Void) {
        consul.catalog.nodes(withService: service).whenComplete { result in
            switch result {
            case .success(let (_, services)):
                callback(.success(services))
            case let .failure(error):
                callback(.failure(error))
            }
        }
    }

    private func subscribe(
        to service: Service,
        onNext nextResultHandler: @escaping @Sendable (Result<[Instance], Error>) -> Void,
        onCompletion completionHandler: @escaping @Sendable (CompletionReason) -> Void,
        cancellationToken: CancellationToken,
        polling poll: Consul.Poll?
    ) {
        consul.catalog.nodes(withService: service, poll: poll).whenComplete { result in
            if cancellationToken.isCancelled {
                completionHandler(.cancellationRequested)
            } else {
                switch result {
                case .success(let (index, services)):
                    nextResultHandler(.success(services))
                    let poll = Consul.Poll(index: index, wait: "10m")
                    self.subscribe(to: service,
                                   onNext: nextResultHandler,
                                   onCompletion: completionHandler,
                                   cancellationToken: cancellationToken,
                                   polling: poll)
                case let .failure(error):
                    nextResultHandler(.failure(error))
                    let eventLoop = self.consul.impl.eventLoopGroup.next()
                    _ = eventLoop.scheduleTask(in: Consul.reconnectInterval) {
                        self.subscribe(to: service,
                                       onNext: nextResultHandler,
                                       onCompletion: completionHandler,
                                       cancellationToken: cancellationToken,
                                       polling: nil)
                    }
                }
            }
        }
    }

    public func subscribe(
        to service: Service,
        onNext nextResultHandler: @escaping @Sendable (Result<[Instance], Error>) -> Void,
        onComplete completionHandler: @escaping @Sendable (CompletionReason) -> Void
    ) -> CancellationToken {
        let cancellationToken = CancellationToken(isCancelled: false, completionHandler: completionHandler)
        subscribe(to: service,
                  onNext: nextResultHandler,
                  onCompletion: completionHandler,
                  cancellationToken: cancellationToken,
                  polling: nil)
        return cancellationToken
    }
}
