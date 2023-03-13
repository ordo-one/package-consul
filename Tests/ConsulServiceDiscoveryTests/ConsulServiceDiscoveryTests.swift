@testable import ConsulServiceDiscovery
import NIOPosix
import XCTest

final class ConsulServiceDiscoveryTests: XCTestCase {
    private var eventLoopGroup: MultiThreadedEventLoopGroup?

    override func setUp() {
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    override func tearDown() {
        do {
            try eventLoopGroup!.syncShutdownGracefully()
        } catch {
            fatalError("\(error)")
        }
    }

    func testLookup() throws {
        let consul = Consul(with: eventLoopGroup!)

        let processInfo = ProcessInfo.processInfo
        let serviceName = "\(processInfo.hostName)-ts-\(processInfo.processIdentifier)"
        let service1 = Consul.AgentService(ID: "\(serviceName)-1", Address: "127.0.0.1", Name: serviceName, Port: 12001)

        let registerFuture1 = consul.agentRegister(service: service1)
        try registerFuture1.wait()

        let service2 = Consul.AgentService(ID: "\(serviceName)-2", Address: "127.0.0.1", Name: serviceName, Port: 12002)
        let registerFuture2 = consul.agentRegister(service: service2)
        try registerFuture2.wait()

        let lookupDone = eventLoopGroup!.next().makePromise(of: Void.self)

        let consulServiceDiscovery = ConsulServiceDiscovery(consul)
        consulServiceDiscovery.lookup(serviceName, deadline: nil) { result in
            switch result {
            case var .success(services):
                XCTAssertEqual(services.count, 2)
                services.sort(by: { $0.ServiceID < $1.ServiceID })
                XCTAssertEqual(services[0].ServiceID, service1.ID)
                XCTAssertEqual(services[1].ServiceID, service2.ID)
                lookupDone.succeed()
            case let .failure(error):
                XCTFail("2 service instances expected: \(error)")
                lookupDone.fail(error)
            }
        }

        try lookupDone.futureResult.wait()

        var deregisterFuture = consul.agentDeregister(serviceID: service1.ID)
        try deregisterFuture.wait()

        deregisterFuture = consul.agentDeregister(serviceID: service2.ID)
        try deregisterFuture.wait()
    }
}
