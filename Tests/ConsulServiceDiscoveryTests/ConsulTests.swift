@testable import ConsulServiceDiscovery
import NIOPosix
import XCTest

final class ConsulTests: XCTestCase {
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

    func testRegisterDeregister() throws {
        let consul = Consul(with: eventLoopGroup!)

        let serviceName = "test_service"
        let processInfo = ProcessInfo.processInfo
        let serviceID = "\(processInfo.hostName)-\(processInfo.processIdentifier)"
        let service = AgentService(id: serviceID, name: serviceName, address: "127.0.0.1", port: 12_345)

        let registerFuture = consul.agentRegister(service: service)
        try registerFuture.wait()

        let servicesFuture = consul.catalogServices()
        let services = try servicesFuture.wait()
        XCTAssertTrue(services.contains(where: { $0 == serviceName }))

        let deregisterFuture = consul.agentDeregister(serviceID: serviceID)
        try deregisterFuture.wait()
    }
}
