@testable import ConsulServiceDiscovery
import NIOPosix
import XCTest

final class ConsulTests: XCTestCase {
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

    func testRegisterDeregister() throws {
        let consul = Consul(with: eventLoopGroup!)

        let processInfo = ProcessInfo.processInfo
        let serviceName = "\(processInfo.hostName)-test_service-\(processInfo.processIdentifier)"
        let service = Consul.AgentService(ID: serviceName, Address: "127.0.0.1", Name: serviceName, Port: 12345)

        let registerFuture = consul.agentRegister(service: service)
        try registerFuture.wait()

        let servicesFuture = consul.catalogServices()
        let services = try servicesFuture.wait()
        XCTAssertTrue(services.contains(where: { $0 == serviceName }))

        let deregisterFuture = consul.agentDeregister(serviceID: serviceName)
        try deregisterFuture.wait()
    }
}
