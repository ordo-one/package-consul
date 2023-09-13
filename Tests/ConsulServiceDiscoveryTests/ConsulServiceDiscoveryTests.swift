@testable import ConsulServiceDiscovery
import NIOPosix
import ServiceDiscovery
import XCTest

final class ConsulServiceDiscoveryTests: XCTestCase {
    func testLookup() throws {
        let consul = Consul()

        let serviceName = "test_service"
        let check = Check(deregisterCriticalServiceAfter: "1m", name: "\(serviceName)-health-check", status: .passing, ttl: "20s")
        let processInfo = ProcessInfo.processInfo
        let serviceID = "\(processInfo.hostName)-\(processInfo.processIdentifier)-testLookup"
        let service1 = Service(checks: [check], id: "\(serviceID)-1", name: serviceName, port: 12_001)

        let registerFuture1 = consul.agent.registerService(service1)
        try registerFuture1.wait()

        let service2 = Service(checks: [check], id: "\(serviceID)-2", name: serviceName, port: 12_002)
        let registerFuture2 = consul.agent.registerService(service2)
        try registerFuture2.wait()

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let lookupDone = eventLoopGroup.next().makePromise(of: Void.self)

        let consulServiceDiscovery = ConsulServiceDiscovery(consul)
        consulServiceDiscovery.lookup(serviceName, deadline: nil) { result in
            switch result {
            case var .success(services):
                services = services.filter { ($0.serviceID == "\(serviceID)-1") || ($0.serviceID == "\(serviceID)-2") }
                services.sort(by: { $0.serviceID < $1.serviceID })
                XCTAssertEqual(services[0].serviceID, service1.id)
                XCTAssertNotNil(services[0].createIndex)
                XCTAssertNotNil(services[0].modifyIndex)
                XCTAssertEqual(services[1].serviceID, service2.id)
                XCTAssertNotNil(services[1].createIndex)
                XCTAssertNotNil(services[1].modifyIndex)
                lookupDone.succeed()
            case let .failure(error):
                XCTFail("2 service instances expected: \(error)")
                lookupDone.fail(error)
            }
        }

        try lookupDone.futureResult.wait()

        let deregisterFuture1 = consul.agent.deregisterServiceID(service1.id!)
        try deregisterFuture1.wait()

        let deregisterFuture2 = consul.agent.deregisterServiceID(service2.id!)
        try deregisterFuture2.wait()

        try eventLoopGroup.syncShutdownGracefully()
        try consul.syncShutdown()
    }

    func testSubscribe() throws {
        let consul = Consul()

        let processInfo = ProcessInfo.processInfo
        let serviceName = "test_service"
        let serviceID = "\(processInfo.hostName)-\(processInfo.processIdentifier)-testSubscribe"
        let check = Check(deregisterCriticalServiceAfter: "1m", name: "\(serviceName)-health-check", status: .passing, ttl: "20s")
        let service = Service(address: "127.0.0.1", checks: [check], id: serviceID, name: serviceName, port: 12_001)
        let registerFuture1 = consul.agent.registerService(service)
        try registerFuture1.wait()

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let done = eventLoopGroup.next().makePromise(of: Void.self)

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
                        let serviceUpdate = Service(checks: [check], id: service.id, name: service.name, port: 12_002)
                        _ = consul.agent.registerService(serviceUpdate)
                    } else {
                        let service = services.first(where: { $0.serviceID == serviceID })
                        if service!.servicePort == 12_002 {
                            done.succeed()
                        }
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

        let deregisterFuture = consul.agent.deregisterServiceID(service.id!)
        try deregisterFuture.wait()

        try eventLoopGroup.syncShutdownGracefully()
        try consul.syncShutdown()
    }

    func testSC1936NonJsonResponseFromConsul() async throws {
        let consul = Consul()
        let consulServiceDiscovery = ConsulServiceDiscovery(consul)
        var cancellationToken: CancellationToken?
        await withCheckedContinuation { continuation in
            cancellationToken = consulServiceDiscovery.subscribe(
                to: "", // name is empty to trigger the error response from Consul
                onNext: { result in
                    switch result {
                    case .success:
                        XCTFail("should not be called")
                    case .failure:
                        continuation.resume()
                    }
                },
                onComplete: { _ in }
            )
        }
        if let cancellationToken {
            cancellationToken.cancel()
        }
        try consul.syncShutdown()
    }
}
