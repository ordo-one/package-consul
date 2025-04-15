
public struct Service: Codable, Sendable {
    /// Specifies the address of the service.
    public let address: String?
    /// The list of Consul checks for the service. Cannot be specified with
    /// `healthSyncContainers`.
    public let checks: [Check]?
    /// Specifies a unique ID for this service.
    public let id: String
    /// Key-value pairs of metadata to include for the Consul service.
    public let meta: [String: String]?
    /// The name the service will be registered as in Consul.
    public let name: String
    /// Port the application listens on, if any.
    public let port: Int?
    /// List of string values that can be used to add service-level labels.
    public let tags: [String]?

    public init(
        address: String? = nil,
        checks: [Check]? = nil,
        id: String,
        meta: [String: String]? = nil,
        name: String,
        port: Int? = nil,
        tags: [String]? = nil
    ) {
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

public struct Check: Codable, Sendable {
    /// Specifies a body that should be sent with HTTP checks.
    public let body: String?
    /// The unique ID for this check on the node. Defaults to the check `name`.
    public let checkID: String?
    /// Specifies that checks associated with a service should deregister after this time.
    public let deregisterCriticalServiceAfter: String?
    /// Specifies an HTTP check to perform a GET request against the value of HTTP (expected to be a URL) every Interval.
    public let http: String?
    /// Specifies the frequency at which to run this check. This is required for HTTP, TCP, and UDP checks.
    public let interval: String?
    /// Specifies a different HTTP method to be used for an HTTP check. When no value is specified, GET is used.
    public let method: String?
    /// The name of the check.
    public let name: String
    /// Specifies the initial status the health check.
    public let status: Status?
    /// Specifies a TCP to connect against the value of TCP (expected to be an IP or hostname plus port combination) every Interval.
    public let tcp: String?
    /// Specifies a timeout for outgoing connections. Applies to script, HTTP, TCP, UDP, and gRPC
    /// checks. Must be a duration string, such as `10s` or `5m`.
    public let timeout: String?
    /// Specifies this is a TTL check. Must be a duration string, such as `10s` or `5m`.
    public let ttl: String?
    /// Specifies a UDP IP address/hostname and port. The check sends datagrams to the value specified at the interval specified in the Interval configuration.
    public let udp: String?

    public init(
        body: String? = nil,
        checkID: String? = nil,
        deregisterCriticalServiceAfter: String? = nil,
        http: String? = nil,
        interval: String? = nil,
        method: String? = nil,
        name: String,
        status: Status? = nil,
        tcp: String? = nil,
        timeout: String? = nil,
        ttl: String? = nil,
        udp: String? = nil
    ) {
        self.body = body
        self.checkID = checkID
        self.deregisterCriticalServiceAfter = deregisterCriticalServiceAfter
        self.http = http
        self.interval = interval
        self.method = method
        self.name = name
        self.status = status
        self.tcp = tcp
        self.timeout = timeout
        self.ttl = ttl
        self.udp = udp
    }

    enum CodingKeys: String, CodingKey {
        case body = "Body"
        case checkID = "CheckID"
        case deregisterCriticalServiceAfter = "DeregisterCriticalServiceAfter"
        case http = "HTTP"
        case interval = "Interval"
        case method = "Method"
        case name = "Name"
        case status = "Status"
        case tcp = "tcp"
        case timeout = "Timeout"
        case ttl = "TTL"
        case udp = "UDP"
    }
}

public enum Status: String, Codable, Sendable {
    case critical
    case passing
    case warning
}

public struct NodeService: Hashable, Decodable, Sendable {
    public let address: String?
    public let createIndex: Int?
    public let datacenter: String?
    public let id: String?
    public let modifyIndex: Int?
    public let node: String?
    public let serviceAddress: String?
    public let serviceID: String
    public let serviceMeta: [String: String]?
    public let serviceName: String?
    public let servicePort: Int?
    public let taggedAddresses: [String: String]?

    public init(
        address: String? = nil,
        createIndex: Int? = nil,
        datacenter: String? = nil,
        id: String? = nil,
        modifyIndex: Int? = nil,
        node: String? = nil,
        serviceAddress: String? = nil,
        serviceID: String,
        serviceMeta: [String: String]? = nil,
        serviceName: String? = nil,
        servicePort: Int? = nil,
        taggedAddresses: [String: String]? = nil
    ) {
        self.address = address
        self.createIndex = createIndex
        self.datacenter = datacenter
        self.id = id
        self.modifyIndex = modifyIndex
        self.node = node
        self.serviceAddress = serviceAddress
        self.serviceID = serviceID
        self.serviceMeta = serviceMeta
        self.serviceName = serviceName
        self.servicePort = servicePort
        self.taggedAddresses = taggedAddresses
    }

    public enum CodingKeys: String, CodingKey {
        case address = "Address"
        case createIndex = "CreateIndex"
        case datacenter = "Datacenter"
        case id = "ID"
        case modifyIndex = "ModifyIndex"
        case node = "Node"
        case serviceAddress = "ServiceAddress"
        case serviceID = "ServiceID"
        case serviceMeta = "ServiceMeta"
        case serviceName = "ServiceName"
        case servicePort = "ServicePort"
        case taggedAddresses = "TaggedAddresses"
    }
}

public struct Value: Hashable, Decodable, Sendable {
    public let flags: Int?
    public let key: String
    public let value: String?
    public let createIndex: Int?
    public let modifyIndex: Int?
    public let lockIndex: Int?
    public let session: String?

    enum CodingKeys: String, CodingKey {
        case flags = "Flags"
        case key = "Key"
        case value = "Value"
        case createIndex = "CreateIndex"
        case modifyIndex = "ModifyIndex"
        case lockIndex = "LockIndex"
        case session = "Session"
    }
}

public struct Session: Codable, Sendable {
    public struct ServiceCheck: Codable, Sendable {
        public let id: String
        public let namespace: String?

        init(_ id: String, namespace: String? = nil) {
            self.id = id
            self.namespace = namespace
        }

        enum CodingKeys: String, CodingKey {
            case id = "ID"
            case namespace = "Namespace"
        }
    }

    // LockDelay parameter for session create request is string,
    // but for session read/renew/list is an integer.
    // weird...
    public struct LockDelay: Codable, Sendable {
        public let ns: Int

        public init(_ ns: Int) {
            self.ns = ns
        }

        public func encode(to encoder: any Encoder) throws {
            let nanosecondsInSecond = 1_000_000_000
            var seconds = (ns / nanosecondsInSecond)
            if (ns % nanosecondsInSecond) > 0 {
                seconds += 1
            }
            var container = encoder.singleValueContainer()
            try container.encode("\(seconds)s")
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            ns = try container.decode(Int.self)
        }
    }

    public let behavior: String?
    public let id: String?
    public let lockDelay: LockDelay?
    public let name: String?
    public let node: String?
    public let nodeChecks: [String]?
    public let serviceChecks: [ServiceCheck]?
    public let ttl: String? // minimum TTL is 10 seconds

    public let createIndex: Int?
    public let modifyIndex: Int?

    public init(
        behavior: String? = nil,
        lockDelay: Int? = nil,
        name: String? = nil,
        nodeChecks: [String]? = nil,
        serviceChecks: [ServiceCheck]? = nil,
        ttl: String? = nil
    ) {
        self.behavior = behavior
        self.id = nil
        self.lockDelay = lockDelay.map { .init($0) }
        self.name = name
        self.node = nil
        self.nodeChecks = nodeChecks
        self.serviceChecks = serviceChecks
        self.ttl = ttl
        self.createIndex = nil
        self.modifyIndex = nil
    }

    enum CodingKeys: String, CodingKey {
        case behavior = "Behavior"
        case id = "ID"
        case lockDelay = "LockDelay"
        case name = "Name"
        case node = "Node"
        case nodeChecks = "NodeChecks"
        case serviceChecks = "ServiceChecks"
        case ttl = "TTL"

        case createIndex = "CreateIndex"
        case modifyIndex = "ModifyIndex"
    }
}
