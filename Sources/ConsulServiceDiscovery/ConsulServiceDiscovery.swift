import Dispatch
import ServiceDiscovery

public final class ConsulServiceDiscovery: ServiceDiscovery {
    public typealias Service = String
    public typealias Instance = Consul.NodeService

    private let consul: Consul

    public init(_ consul: Consul) {
        self.consul = consul
    }

    public let defaultLookupTimeout: DispatchTimeInterval = .seconds(1)

    public func lookup(_ service: Service, deadline _: DispatchTime?, callback: @escaping (Result<[Instance], Error>) -> Void) {
        consul.catalogNodes(withService: service).whenComplete { result in
            callback(result)
        }
    }

    public func subscribe(to _: Service,
                          onNext _: @escaping (Result<[Instance], Error>) -> Void,
                          onComplete completionHandler: @escaping (CompletionReason) -> Void) -> CancellationToken
    {
        return CancellationToken(isCancelled: false, completionHandler: completionHandler)
    }
}
