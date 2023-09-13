# package-consul

Swift client for consul HTTP API and a [Swift Service Discovery](https://github.com/apple/swift-service-discovery) backend for Consul.

Work still in progress.

Limited support for base endpoints: agent, catalog, health and kv.
Other endpoints support will be added later.

## How to add into your project

Using Swift Package manager: 
Add package-consul to the package dependencies:
```
    dependencies: [
        ...
        .package(url: "https://github.com/ordo-one/package-consul", .upToNextMajor(from: "2.0.0")),
        ...
    ],    
```
and dependency to the particular build target:
```
        .target(
            name: "MyOutstandingTarget",
            dependencies: [
                ...
                .product(name: "ConsulServiceDiscovery", package: "package-consul"),
                ...
            ]
        ),
```

## How to use Consul API
```
    let consul = Consul()
    let service = Service(id: "5c3098a4-3066-11ee-be56-0242ac120002", name: "MyFancyService", port: 12_345)
    let registerFuture = consul.agent.registerService(service)
    try registerFuture.wait()
```

## How to use Swift Service Discovery with Consul backend
```
    let consul = Consul()
    let consulServiceDiscovery = ConsulServiceDiscovery(consul)
    let cancellationToken = consulServiceDiscovery.subscribe(
        to: serviceName,
        onNext: { result in
            switch result {
            case let .success(services):
                for service in services {
                    print("Found service \(service.serviceID)")
                }
            case let .failure(error):
                print("Discovery error: \(error)")
            }
        },
        onComplete: { _ in }
    )
    ...
    cancellationToken.cancel()
```
