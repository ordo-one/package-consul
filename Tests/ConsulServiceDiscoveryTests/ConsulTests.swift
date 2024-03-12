@testable import ConsulServiceDiscovery
import NIOPosix
import XCTest

final class ConsulTests: XCTestCase {
    func testRegisterDeregister() throws {
        let consul = Consul()

        let serviceName = "test_service"
        let processInfo = ProcessInfo.processInfo
        let serviceID = "\(processInfo.hostName)-\(processInfo.processIdentifier)-\(serviceName)-\(#line)"

        let check = Check(deregisterCriticalServiceAfter: "1m", name: "\(serviceName)-health-check", status: .passing, ttl: "30s")
        let service = Service(checks: [check], id: serviceID, name: serviceName, port: 12_345)

        let registerFuture = consul.agent.registerService(service)
        try registerFuture.wait()

        let servicesFuture = consul.catalog.services()
        let services = try servicesFuture.wait()
        XCTAssertTrue(services.contains(where: { $0 == serviceName }))

        let deregisterFuture = consul.agent.deregisterServiceID(serviceID)
        try deregisterFuture.wait()

        try consul.syncShutdown()
    }

    func testHealthCheckError() async throws {
        // Try to update health status for service which has not been registered.
        let consul = Consul()

        let serviceName = "test_service"
        let processInfo = ProcessInfo.processInfo
        let serviceID = "\(processInfo.hostName)-\(processInfo.processIdentifier)-\(serviceName)-\(#line)"

        let checkID = "service:\(serviceID)"
        let future = consul.agent.check(checkID, status: .passing)

        var continuation: AsyncStream<Result<Void, Error>>.Continuation?
        let stream = AsyncStream<Result<Void, Error>>() { continuation = $0 }
        guard let continuation else { fatalError("continuation unexpectedly nil") }

        future.whenComplete { result in
            continuation.yield(result)
        }

        for await result in stream {
            switch result {
            case .success:
                XCTFail("check update unexpectedly succeeded")
            case let .failure(error):
                if let error = error as? ConsulError,
                   case let .httpResponseError(responseStatus) = error,
                   responseStatus == .notFound {
                    // expected error
                } else {
                    XCTFail("unexpected error \(error)")
                }
            }
            break
        }

        try consul.syncShutdown()
    }

    func testSC1936NonJsonResponseFromConsul() throws {
        let consul = Consul()
        let check = {
            let future = consul.catalog.nodes(withService: "")
            _ = try future.wait()
        }
        XCTAssertThrowsError(try check())
        try consul.syncShutdown()
    }

    func testKV() throws {
        let testValue = "test-value"
        let consul = Consul()

        let processInfo = ProcessInfo.processInfo
        let testKey = "test-key-\(processInfo.hostName)-\(processInfo.processIdentifier)"
        let future1 = consul.kv.updateValue(testValue, forKey: testKey)
        _ = try future1.wait()

        let future2 = consul.kv.keys()
        let keys2 = try future2.wait()
        XCTAssertTrue(keys2.contains(where: { $0 == testKey }))

        let future3 = consul.kv.valueForKey(testKey)
        let value = try future3.wait()

        let valueValue = try XCTUnwrap(value.value, "value is unexpectedly empty")
        let data = try XCTUnwrap(Data(base64Encoded: valueValue), "can't decode value")
        let str = try XCTUnwrap(String(data: data, encoding: .utf8), "can't construct string")
        XCTAssertEqual(str, testValue)

        let future4 = consul.kv.removeValue(forKey: testKey)
        try future4.wait()

        let future5 = consul.kv.keys()
        let keys5 = try future5.wait()
        XCTAssertFalse(keys5.contains(where: { $0 == testKey }))

        try consul.syncShutdown()
    }
}
