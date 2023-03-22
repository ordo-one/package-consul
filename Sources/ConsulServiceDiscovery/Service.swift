import Foundation

public struct Service: Codable {
    /// Specifies the address of the service.
    let address: String?
    /// The list of Consul checks for the service. Cannot be specified with
    /// `healthSyncContainers`.
    let checks: [Check]?
    /// Specifies a unique ID for this service.
    let id: String?
    /// Key-value pairs of metadata to include for the Consul service.
    let meta: [String: String]?
    /// The name the service will be registered as in Consul. Defaults to the Task family name if
    /// empty or null.
    let name: String?
    /// Port the application listens on, if any.
    let port: Int?
    /// List of string values that can be used to add service-level labels.
    let tags: [String]?

    init(address: String? = nil, checks: [Check]? = nil, id: String? = nil, meta: [String: String]? = nil, name: String? = nil, port: Int? = nil, tags: [String]? = nil) {
        self.address = address
        self.checks = checks
        self.id = id
        self.meta = meta
        self.name = name
        self.port = port
        self.tags = tags
    }

    enum CodingKeys: String, CodingKey {
        case address = "Address"
        case checks = "Checks"
        case id = "ID"
        case meta = "Meta"
        case name = "Name"
        case port = "Port"
        case tags = "Tags"
    }
}

public struct Check: Codable {
    /// The unique ID for this check on the node. Defaults to the check `name`.
    let checkID: String?
    /// Specifies that checks associated with a service should deregister after this time.
    let deregisterCriticalServiceAfter: String?
    /// The name of the check.
    let name: String?
    /// Specifies the initial status the health check.
    let status: Status?
    /// Specifies a timeout for outgoing connections. Applies to script, HTTP, TCP, UDP, and gRPC
    /// checks. Must be a duration string, such as `10s` or `5m`.
    let timeout: String?
    /// Specifies this is a TTL check. Must be a duration string, such as `10s` or `5m`.
    let ttl: String?

    init(checkID: String? = nil, deregisterCriticalServiceAfter: String? = nil, name: String? = nil, status: Status? = nil, timeout: String? = nil, ttl: String? = nil) {
        self.checkID = checkID
        self.deregisterCriticalServiceAfter = deregisterCriticalServiceAfter
        self.name = name
        self.status = status
        self.timeout = timeout
        self.ttl = ttl
    }

    enum CodingKeys: String, CodingKey {
        case checkID = "checkId"
        case deregisterCriticalServiceAfter = "DeregisterCriticalServiceAfter"
        case name = "Name"
        case status = "Status"
        case timeout = "Timeout"
        case ttl = "TTL"
    }
}

public enum Status: String, Codable {
    case critical
    case maintenance
    case passing
    case warning
}

public struct NodeService: Hashable, Decodable {
    public let address: String?
    public let datacenter: String?
    public let id: String?
    public let node: String?
    public let serviceAddress: String?
    public let serviceID: String
    public let serviceMeta: [String: String]?
    public let serviceName: String?
    public let servicePort: Int?

    enum CodingKeys: String, CodingKey {
        case address = "Address"
        case datacenter = "Datacenter"
        case id = "ID"
        case node = "Node"
        case serviceAddress = "ServiceAddress"
        case serviceID = "ServiceID"
        case serviceMeta = "ServiceMeta"
        case serviceName = "ServiceName"
        case servicePort = "ServicePort"
    }
}
