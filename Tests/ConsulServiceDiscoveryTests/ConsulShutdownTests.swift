import ConsulServiceDiscovery
import Testing

struct ConsulShutdownTests {
    @Test
    func shutdownReturnsAndASecondOneIsHarmless() async throws {
        let consul = Consul()
        try await consul.shutdown()
        try await consul.shutdown()
    }
}
