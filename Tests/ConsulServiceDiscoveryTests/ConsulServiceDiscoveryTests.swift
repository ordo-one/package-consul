@testable import ConsulServiceDiscovery
import NIOPosix
import XCTest

final class ConsulServiceDiscoveryTests: XCTestCase {
    private var eventLoopGroup: MultiThreadedEventLoopGroup?

    override func setUp() {
        super.setUp()
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    override func tearDown() {
        do {
            try eventLoopGroup!.syncShutdownGracefully()
        } catch {
            fatalError("\(error)")
        }
        super.tearDown()
    }

    func testLookup() throws {
        let consul = Consul(with: eventLoopGroup!)

        let processInfo = ProcessInfo.processInfo
        let serviceName = "test_service"
        let serviceID = "\(processInfo.hostName)-\(processInfo.processIdentifier)"
        let service1 = AgentService(id: "\(serviceID)-1", name: serviceName, address: "127.0.0.1", port: 12_001)

        let registerFuture1 = consul.agentRegister(service: service1)
        try registerFuture1.wait()

        let service2 = AgentService(id: "\(serviceID)-2", name: serviceName, address: "127.0.0.1", port: 12_002)
        let registerFuture2 = consul.agentRegister(service: service2)
        try registerFuture2.wait()

        let lookupDone = eventLoopGroup!.next().makePromise(of: Void.self)

        let consulServiceDiscovery = ConsulServiceDiscovery(consul)
        consulServiceDiscovery.lookup(serviceName, deadline: nil) { result in
            switch result {
            case var .success(services):
                services = services.filter { ($0.serviceID == "\(serviceID)-1") || ($0.serviceID == "\(serviceID)-2") }
                services.sort(by: { $0.serviceID < $1.serviceID })
                XCTAssertEqual(services[0].serviceID, service1.id)
                XCTAssertEqual(services[1].serviceID, service2.id)
                lookupDone.succeed()
            case let .failure(error):
                XCTFail("2 service instances expected: \(error)")
                lookupDone.fail(error)
            }
        }

        try lookupDone.futureResult.wait()

        let deregisterFuture1 = consul.agentDeregister(serviceID: service1.id)
        try deregisterFuture1.wait()

        let deregisterFuture2 = consul.agentDeregister(serviceID: service2.id)
        try deregisterFuture2.wait()
    }

    func testSubscribe() throws {
        let consul = Consul(with: eventLoopGroup!)

        let processInfo = ProcessInfo.processInfo
        let serviceName = "test_service"
        let serviceID = "\(processInfo.hostName)-\(processInfo.processIdentifier)"
        let service = AgentService(id: serviceID, name: serviceName, address: "127.0.0.1", port: 12_001)

        let registerFuture1 = consul.agentRegister(service: service)
        try registerFuture1.wait()

        let done = eventLoopGroup!.next().makePromise(of: Void.self)

        var nextResultHandlerCalledTimes = 0

        let consulServiceDiscovery = ConsulServiceDiscovery(consul)
        let cancellationToken = consulServiceDiscovery.subscribe(
            to: serviceName,
            onNext: { result in
                switch result {
                case let .success(services):
                    nextResultHandlerCalledTimes += 1
                    if nextResultHandlerCalledTimes == 1 {
                        // update service with a different port number
                        let serviceUpdate = AgentService(id: service.id, name: service.name, address: service.address, port: 12_002)
                        _ = consul.agentRegister(service: serviceUpdate)
                    } else {
                        let service = services.first(where: { $0.serviceID == serviceID })
                        XCTAssertEqual(service!.servicePort, 12_002)
                        done.succeed()
                    }
                case let .failure(error):
                    XCTFail("2 service instances expected: \(error)")
                    done.fail(error)
                }
            },
            onComplete: { _ in }
        )

        try done.futureResult.wait()
        cancellationToken.cancel()

        let deregisterFuture = consul.agentDeregister(serviceID: service.id)
        try deregisterFuture.wait()
    }
}
