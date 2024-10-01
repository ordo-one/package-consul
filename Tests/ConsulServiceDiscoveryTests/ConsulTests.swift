@testable import ConsulServiceDiscovery
import NIOPosix
import class NIOCore.EventLoopFuture
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

        do {
            let servicesFuture = consul.catalog.services()
            let services = try servicesFuture.wait()
            XCTAssertTrue(services.contains(where: { $0 == serviceName }))
        }

        do {
            let nodesFuture = consul.catalog.nodes(withService: serviceName)
            let (_, services) = try nodesFuture.wait()
            let service = services.first(where: { ($0.serviceName == serviceName) && ($0.serviceID == serviceID) })
            XCTAssertNotNil(service)
        }

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
        let (stream, continuation) = AsyncStream.makeStream(of: Result<Void, Error>.self)

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
        let value = try XCTUnwrap(future3.wait(), "value is unexpectedly empty")

        let valueValue = try XCTUnwrap(value.value, "value.value is unexpectedly empty")
        XCTAssertEqual(valueValue, testValue)

        let future4 = consul.kv.removeValue(forKey: testKey)
        try future4.wait()

        let future5 = consul.kv.keys()
        let keys5 = try future5.wait()
        XCTAssertFalse(keys5.contains(where: { $0 == testKey }))

        try consul.syncShutdown()
    }

    func testKVDoesNotExist() throws {
        let consul = Consul()

        let testKey = "test-key-does-not-exist"
        let future1 = consul.kv.valueForKey(testKey)
        let value = try future1.wait()
        XCTAssertEqual(value, nil)

        try consul.syncShutdown()
    }

    func testKVLock() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let consul = Consul()

        let session1 = Session(lockDelay: "1s", ttl: "10s")
        let session1Future = consul.session.create(session1)
        let session1Id = try session1Future.wait()
        print("session1=\(session1Id)")

        let session2 = Session(lockDelay: "1s", ttl: "10s")
        let session2Future = consul.session.create(session2)
        let session2Id = try session2Future.wait()
        print("session2=\(session2Id)")

        let key = "key1-\(pid)"
        let update1Future = consul.kv.updateValue("value1", forKey: key, lockOp: .acquire(session1Id))
        let update1Result = try update1Future.wait()
        XCTAssertTrue(update1Result)

        let update2Future = consul.kv.updateValue("value2", forKey: key, lockOp: .acquire(session2Id))
        let update2Result = try update2Future.wait()
        XCTAssertFalse(update2Result)

        let removeValueFuture = consul.kv.removeValue(forKey: key)
        let removeValueResult = try removeValueFuture.wait()
        XCTAssertTrue(removeValueResult)
    }
}
