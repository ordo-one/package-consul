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
        let serviceID = "\(processInfo.hostName)-\(processInfo.processIdentifier)-\(serviceName)"

        let check = Check(deregisterCriticalServiceAfter: "1m", name: "\(serviceName)-health-check", status: .passing, ttl: "30s")
        let service = Service(checks: [check], id: serviceID, name: serviceName, port: 12_345)

        let registerFuture = consul.agentRegisterService(service)
        try registerFuture.wait()

        let servicesFuture = consul.catalogServices()
        let services = try servicesFuture.wait()
        XCTAssertTrue(services.contains(where: { $0 == serviceName }))

        let deregisterFuture = consul.agentDeregisterServiceID(serviceID)
        try deregisterFuture.wait()
    }
}
