import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

public enum ConsulError: Error {
    case failedToConnect(String)
    case httpResponseError(HTTPResponseStatus)
    case failedToDecodeValue(String)
    case error(String)
}

protocol ConsulResponseHandler: Sendable {
    func processResponse(_ buffer: ByteBuffer, withIndex: Int?)
    func fail(_ error: Error)
}

public final class Consul: Sendable {
    static let reconnectInterval: TimeAmount = .seconds(5)

    public static var defaultHost: String {
        let defaultHost = "127.0.0.1"

        guard let consulHTTPAdress = ProcessInfo.processInfo.environment["CONSUL_HTTP_ADDR"] else {
            return defaultHost
        }

        guard let urlHost = URL(string: consulHTTPAdress)?.host else {
            return defaultHost
        }

        return urlHost
    }

    public static var defaultPort: Int {
        let defaultPort = 8_500

        guard let consulHTTPAdress = ProcessInfo.processInfo.environment["CONSUL_HTTP_ADDR"] else {
            return defaultPort
        }

        guard let urlPort = URL(string: consulHTTPAdress)?.port else {
            return defaultPort
        }

        return urlPort
    }

    public struct AgentEndpoint: Sendable {
        private let impl: Impl

        fileprivate init(_ impl: Impl) {
            self.impl = impl
        }

        /// Register a new service via local agent.
        /// - Parameter service: service to register
        /// - Returns: EventLoopFuture<Void> to deliver result
        /// [apidoc]: https://www.consul.io/api/agent/service.html#register-service
        ///
        public func registerService(_ service: Service) -> EventLoopFuture<Void> {
            impl.logger.debug("register service \(service.id)")
            let promise = impl.makePromise(of: Void.self)
            do {
                let data = try JSONEncoder().encode(service)
                var requestBody = ByteBufferAllocator().buffer(capacity: data.count)
                requestBody.writeBytes(data)
                impl.request(method: .PUT, uri: "/v1/agent/service/register", body: requestBody, handler: ResponseHandlerVoid(promise))
            } catch {
                promise.fail(error)
            }
            return promise.futureResult
        }

        /// Deregister a service via local agent
        /// - Parameter serviceID: service to deregister
        /// - Returns: EventLoopFuture<Void> to deliver result
        /// [apidoc]: https://developer.hashicorp.com/consul/api-docs/agent/service#deregister-service
        ///
        public func deregisterServiceID(_ serviceID: String) -> EventLoopFuture<Void> {
            let promise = impl.makePromise(of: Void.self)
            impl.request(method: .PUT, uri: "/v1/agent/service/deregister/\(serviceID)", body: nil, handler: ResponseHandlerVoid(promise))
            return promise.futureResult
        }

        /// Register check
        /// - Parameter check: check description
        /// - Returns: EventLoopFuture<Void> to deliver result
        /// [apidoc] https://developer.hashicorp.com/consul/api-docs/agent/check#register-check
        ///
        public func registerCheck(_ check: Check) -> EventLoopFuture<Void> {
            impl.logger.debug("register check \(check.name)")
            do {
                let data = try JSONEncoder().encode(check)
                var requestBody = ByteBufferAllocator().buffer(capacity: data.count)
                requestBody.writeBytes(data)
                let promise = impl.makePromise(of: Void.self)
                impl.request(method: .PUT, uri: "/v1/agent/check/register", body: requestBody, handler: ResponseHandlerVoid(promise))
                return promise.futureResult
            } catch {
                return impl.makeFailedFuture(error)
            }
        }

        /// Deregister check
        /// - Parameter checkId: check identifier
        /// - Returns: EventLoopFuture<Void> to deliver result
        /// [apidoc] https://developer.hashicorp.com/consul/api-docs/agent/check#deregister-check
        ///
        public func deregisterCheck(_ checkId: String) -> EventLoopFuture<Void> {
            impl.logger.debug("deregister check \(checkId)")
            let promise = impl.makePromise(of: Void.self)
            let uri = "/v1/agent/check/deregister/\(checkId)"
            impl.request(method: .PUT, uri: uri, body: nil, handler: ResponseHandlerVoid(promise))
            return promise.futureResult
        }

        /// Set the status of the check and to reset the TTL clock.
        public func check(_ checkID: String, status: Status) -> EventLoopFuture<Void> {
            var uri: String
            switch status {
            case .passing:
                uri = "pass"
            case .warning:
                uri = "warn"
            case .critical:
                uri = "fail"
            }
            let promise = impl.makePromise(of: Void.self)
            uri = "/v1/agent/check/\(uri)/\(checkID)"
            impl.request(method: .PUT, uri: uri, body: nil, handler: ResponseHandlerVoid(promise))
            return promise.futureResult
        }
    }

    public struct CatalogEndpoint: Sendable {
        private let impl: Impl

        fileprivate init(_ impl: Impl) {
            self.impl = impl
        }

        /// Returns the services registered in a given datacenter.
        /// - Parameter datacenter: Specifies the datacenter to query. This will default to the datacenter of the agent being queried.
        /// - Returns: EventLoopFuture<[String]> to deliver result
        /// [apidoc]: https://developer.hashicorp.com/consul/api-docs/catalog#list-services
        ///
        public func services(inDatacenter datacenter: String? = nil) -> EventLoopFuture<[String]> {
            struct ResponseHandler: ConsulResponseHandler {
                private let promise: EventLoopPromise<[String]>

                init(_ promise: EventLoopPromise<[String]>) {
                    self.promise = promise
                }

                func processResponse(_ buffer: ByteBuffer, withIndex _: Int?) {
                    do {
                        var buffer = buffer
                        let bytes = buffer.readBytes(length: buffer.readableBytes)
                        if let bytes {
                            let dict = try JSONDecoder().decode([String: [String]].self, from: Data(bytes))
                            promise.succeed(Array(dict.keys))
                        } else {
                            promise.fail(ConsulError.error("ByteBuffer.readBytes() unexpectedly returned nil"))
                        }
                    } catch {
                        promise.fail(error)
                    }
                }

                func fail(_ error: Error) {
                    promise.fail(error)
                }
            }

            var components = URLComponents()
            components.path = "/v1/catalog/services"

            if let datacenter, !datacenter.isEmpty {
                components.queryItems = [URLQueryItem(name: "dc", value: datacenter)]
            }

            if let requestURI = components.string {
                let promise = impl.makePromise(of: [String].self)
                impl.request(method: .GET, uri: requestURI, body: nil, handler: ResponseHandler(promise))
                return promise.futureResult
            } else {
                return impl.makeFailedFuture(ConsulError.error("Can not build Consul API request string"))
            }
        }

        /// Returns the nodes providing a service in a given datacenter.
        /// - Parameters
        ///    - datacenter: Specifies the datacenter to query. This will default to the datacenter of the agent being queried.
        ///    - serviceName: Specifies the name of the service for which to list nodes.
        /// - Returns: EventLoopFuture<(Int, [NodeService])> to deliver result where first element of tuple is value of "X-Consul-Index" from HTTP header
        /// [apidoc]: https://developer.hashicorp.com/consul/api-docs/catalog#list-nodes-for-service
        ///
        public func nodes(inDatacenter datacenter: String? = nil,
                          withService serviceName: String,
                          poll: Poll? = nil) -> EventLoopFuture<(Int, [NodeService])> {
            struct ResponseHandler: ConsulResponseHandler {
                private let promise: EventLoopPromise<(Int, [NodeService])>

                init(_ promise: EventLoopPromise<(Int, [NodeService])>) {
                    self.promise = promise
                }

                func processResponse(_ buffer: ByteBuffer, withIndex: Int?) {
                    guard let withIndex else {
                        promise.fail(ConsulError.error("Consul response has no index"))
                        return
                    }

                    guard let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) else {
                        fatalError("Internal error: ByteBuffer.getBytes() unexpectedly returned nil")
                    }

                    do {
                        let services = try JSONDecoder().decode([NodeService].self, from: Data(bytes))
                        promise.succeed((withIndex, services))
                    } catch {
                        guard let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) else {
                            fatalError("Internal error: ByteBuffer.getString() unexpectedly returned nil")
                        }
                        promise.fail(ConsulError.error("Consul response '\(str)' is not a valid JSON"))
                    }
                }

                func fail(_ error: Error) {
                    promise.fail(error)
                }
            }

            var queryItems: [URLQueryItem] = []

            if let datacenter, !datacenter.isEmpty {
                queryItems.append(URLQueryItem(name: "dc", value: datacenter))
            }

            if let poll {
                queryItems.append(URLQueryItem(name: "index", value: "\(poll.index)"))
                if let wait = poll.wait {
                    queryItems.append(URLQueryItem(name: "wait", value: wait))
                }
            }

            var components = URLComponents()
            components.path = "/v1/catalog/service/\(serviceName)"
            if !queryItems.isEmpty {
                components.queryItems = queryItems
            }

            let promise = impl.makePromise(of: (Int, [NodeService]).self)
            if let requestURI = components.string {
                impl.request(method: .GET, uri: requestURI, body: nil, handler: ResponseHandler(promise))
            } else {
                promise.fail(ConsulError.error("Can not build Consul API request string"))
            }
            return promise.futureResult
        }
    }

    public struct KeyValueEndpoint: Sendable {
        private let impl: Impl

        fileprivate init(_ impl: Impl) {
            self.impl = impl
        }

        /// Returns list of keys in KV store.
        /// - Parameters
        ///    - datacenter: Specifies the datacenter to query. This will default to the datacenter of the agent being queried.
        /// - Returns: EventLoopFuture<[String]> to deliver result
        /// [apidoc]: https://developer.hashicorp.com/consul/api-docs/kv#read-key
        ///
        public func keys(inDatacenter datacenter: String? = nil) -> EventLoopFuture<[String]> {
            var components = URLComponents()
            components.path = "/v1/kv/"

            var queryItems = [URLQueryItem(name: "keys", value: nil)]
            if let datacenter, !datacenter.isEmpty {
                queryItems.append(URLQueryItem(name: "dc", value: datacenter))
            }
            components.queryItems = queryItems

            let promise = impl.makePromise(of: [String].self)
            if let requestURI = components.string {
                impl.request(method: .GET, uri: requestURI, body: nil, handler: ResponseHandler(promise))
            } else {
                promise.fail(ConsulError.error("Can not build Consul API request string"))
            }

            return promise.futureResult
        }

        public enum LockOp {
            case acquire(String)
            case release(String)
        }

        /// Updates the value of the specified key. If no key exists at the given path, the key will be created.
        /// - Parameters
        ///    - value: value to store
        ///    - key: specifies the path of the key
        ///    - datacenter: Specifies the datacenter to query. This will default to the datacenter of the agent being queried.
        ///    - cas: Specifies to use a Check-And-Set operation.
        ///    - lockOp: Supply a session ID to use in a lock acquisition or releasing operation.
        /// - Returns: EventLoopFuture<Bool> to deliver result
        /// [apidoc]: https://developer.hashicorp.com/consul/api-docs/kv#create-update-key
        ///
        public func updateValue(
            _ value: String,
            forKey key: String,
            inDatacenter datacenter: String? = nil,
            cas: Int? = nil,
            lockOp: LockOp? = nil
        ) -> EventLoopFuture<Bool> {
            var components = URLComponents()
            components.path = "/v1/kv/\(key)"

            var queryItems = [URLQueryItem]()
            if let datacenter, !datacenter.isEmpty {
                queryItems.append(URLQueryItem(name: "dc", value: datacenter))
            }

            if let cas {
                queryItems.append(URLQueryItem(name: "cas", value: "\(cas)"))
            }

            if let lockOp {
                let queryItem = switch lockOp {
                case .acquire(let session): URLQueryItem(name: "acquire", value: session)
                case .release(let session): URLQueryItem(name: "release", value: session)
                }
                queryItems.append(queryItem)
            }

            if !queryItems.isEmpty {
                components.queryItems = queryItems
            }

            var requestBody = ByteBufferAllocator().buffer(capacity: value.count)
            requestBody.writeString(value)

            let promise = impl.makePromise(of: Bool.self)
            if let requestURI = components.string {
                impl.request(method: .PUT, uri: requestURI, body: requestBody, handler: ResponseHandler(promise))
            } else {
                promise.fail(ConsulError.error("Can not build Consul API request string"))
            }

            return promise.futureResult
        }

        /// Returns the value for specified key.
        /// - Parameters
        ///    - key: specifies the path of the key
        ///    - datacenter: Specifies the datacenter to query. This will default to the datacenter of the agent being queried.
        /// - Returns: EventLoopFuture<Value?> to deliver result, future will sucess with 'nil' if key does not exist
        /// [apidoc]: https://developer.hashicorp.com/consul/api-docs/kv#read-key
        ///
        public func valueForKey(_ key: String, inDatacenter datacenter: String? = nil) -> EventLoopFuture<Value?> {
            struct ResponseHandler: ConsulResponseHandler {
                private let promise: EventLoopPromise<Value?>

                init(_ promise: EventLoopPromise<Value?>) {
                    self.promise = promise
                }

                func processResponse(_ buffer: ByteBuffer, withIndex: Int?) {
                    if buffer.readableBytes == 0 {
                        promise.succeed(nil)
                        return
                    }

                    guard let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) else {
                        fatalError("Internal error: bytes unexpectedly nil")
                    }

                    do {
                        let values = try JSONDecoder().decode([Value].self, from: Data(bytes))
                        if values.count > 0 {
                            let value = values[0]
                            if let valueValue = value.value {
                                if let data = Data(base64Encoded: valueValue), let str = String(data: data, encoding: .utf8) {
                                    let result = Value(flags: value.flags,
                                                       key: value.key,
                                                       value: str,
                                                       createIndex: value.createIndex,
                                                       modifyIndex: value.modifyIndex,
                                                       lockIndex: value.lockIndex,
                                                       session: value.session)
                                    promise.succeed(result)
                                } else {
                                    promise.fail(ConsulError.failedToDecodeValue(valueValue))
                                }
                            } else {
                                // nothing to decode
                                promise.succeed(value)
                            }
                        } else {
                            promise.fail(ConsulError.error("Empty array received"))
                        }
                    } catch {
                        guard let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) else {
                            fatalError("Internal error: failed to fetch string from the buffer")
                        }
                        promise.fail(ConsulError.error("Failed to decode response '\(str)': \(error)"))
                    }
                }

                func fail(_ error: Error) {
                    promise.fail(error)
                }
            }

            var components = URLComponents()
            components.path = "/v1/kv/\(key)"

            var queryItems = [URLQueryItem]()
            if let datacenter, !datacenter.isEmpty {
                queryItems.append(URLQueryItem(name: "dc", value: datacenter))
            }

            if !queryItems.isEmpty {
                components.queryItems = queryItems
            }

            if let requestURI = components.string {
                let promise = impl.makePromise(of: Value?.self)
                impl.request(method: .GET, uri: requestURI, body: nil, handler: ResponseHandler(promise))
                return promise.futureResult
            } else {
                return impl.makeFailedFuture(ConsulError.error("Can not build Consul API request string"))
            }
        }

        /// Deletes a single key or all keys sharing a prefix.
        /// - Parameters
        ///    - key: specifies the path of the key
        ///    - datacenter: Specifies the datacenter to query. This will default to the datacenter of the agent being queried.
        ///    - cas: Specifies to use a Check-And-Set operation.
        ///    - recurse: Specifies to delete all keys which have the specified prefix. Without this, only a key with an exact match will be deleted.
        /// - Returns: EventLoopFuture<Bool> to deliver result
        /// [apidoc]: https://developer.hashicorp.com/consul/api-docs/kv#delete-key
        ///
        public func removeValue(
            forKey key: String,
            inDatacenter datacenter: String? = nil,
            cas: Int? = nil,
            recurse: Bool? = nil
        ) -> EventLoopFuture<Bool> {
            var components = URLComponents()
            components.path = "/v1/kv/\(key)"

            var queryItems = [URLQueryItem]()
            if let datacenter, !datacenter.isEmpty {
                queryItems.append(URLQueryItem(name: "dc", value: datacenter))
            }

            if let cas {
                queryItems.append(URLQueryItem(name: "cas", value: "\(cas)"))
            }

            if let recurse, recurse {
                queryItems.append(URLQueryItem(name: "recurse", value: "true"))
            }

            if !queryItems.isEmpty {
                components.queryItems = queryItems
            }

            if let requestURI = components.string {
                let promise = impl.makePromise(of: Bool.self)
                impl.request(method: .DELETE, uri: requestURI, body: nil, handler: ResponseHandler(promise))
                return promise.futureResult
            } else {
                return impl.makeFailedFuture(ConsulError.error("Can not build Consul API request string"))
            }
        }
    }

    public struct SessionEndpoint: Sendable {
        struct CreateResponse: Decodable {
            let id: String

            enum CodingKeys: String, CodingKey {
                case id = "ID"
            }
        }

        private let impl: Impl

        fileprivate init(_ impl: Impl) {
            self.impl = impl
        }

        /// Creates new session
        /// - Parameters
        ///    - session: session to create
        ///    - datacenter: Specifies the datacenter to query. This will default to the datacenter of the agent being queried.
        /// - Returns: EventLoopFuture<String> to deliver result
        /// [apidoc]: https://developer.hashicorp.com/consul/api-docs/session#create-session
        ///
        public func create(_ session: Session, inDatacenter datacenter: String? = nil) -> EventLoopFuture<String> {
            struct ResponseHandler: ConsulResponseHandler {
                private let promise: EventLoopPromise<String>

                init(_ promise: EventLoopPromise<String>) {
                    self.promise = promise
                }

                func processResponse(_ buffer: ByteBuffer, withIndex _: Int?) {
                    guard let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) else {
                        fatalError("Internal error: bytes unexpectedly nil")
                    }

                    do {
                        let response = try JSONDecoder().decode(CreateResponse.self, from: Data(bytes))
                        promise.succeed(response.id)
                    } catch {
                        guard let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) else {
                            fatalError("Internal error: failed to fetch string from the buffer")
                        }
                        promise.fail(ConsulError.error("Failed to decode response '\(str)': \(error)"))
                    }
                }

                func fail(_ error: any Error) {
                    promise.fail(error)
                }
            }

            var components = URLComponents()
            components.path = "/v1/session/create"

            var queryItems = [URLQueryItem]()
            if let datacenter, !datacenter.isEmpty {
                queryItems.append(URLQueryItem(name: "dc", value: datacenter))
            }

            if !queryItems.isEmpty {
                components.queryItems = queryItems
            }

            do {
                let bytes = try JSONEncoder().encode(session)
                var requestBody = ByteBufferAllocator().buffer(capacity: bytes.count)
                requestBody.writeBytes(bytes)
                if let requestURI = components.string {
                    let promise = impl.makePromise(of: String.self)
                    impl.request(method: .PUT, uri: requestURI, body: requestBody, handler: ResponseHandler(promise))
                    return promise.futureResult
                } else {
                    return impl.makeFailedFuture(ConsulError.error("Can not build Consul API request string"))
                }
            } catch {
                return impl.makeFailedFuture(error)
            }
        }

        /// Destroys existing session
        /// - Parameters
        ///    - id: identifier of the session to destroy
        ///    - datacenter: Specifies the datacenter to query. This will default to the datacenter of the agent being queried.
        /// - Returns: EventLoopFuture<Bool> to deliver result
        /// [apidoc]: https://developer.hashicorp.com/consul/api-docs/session#delete-session
        ///
        public func destroy(_ id: String, inDatacenter datacenter: String? = nil) -> EventLoopFuture<Bool> {
            var components = URLComponents()
            components.path = "/v1/session/destroy/\(id)"

            var queryItems = [URLQueryItem]()
            if let datacenter, !datacenter.isEmpty {
                queryItems.append(URLQueryItem(name: "dc", value: datacenter))
            }

            if !queryItems.isEmpty {
                components.queryItems = queryItems
            }

            if let requestURI = components.string {
                let promise = impl.makePromise(of: Bool.self)
                impl.request(method: .PUT, uri: requestURI, body: nil, handler: ResponseHandler(promise))
                return promise.futureResult
            } else {
                return impl.makeFailedFuture(ConsulError.error("Can not build Consul API request string"))
            }
        }

        /// List existing sessions
        /// - Parameters
        ///    - datacenter: Specifies the datacenter to query. This will default to the datacenter of the agent being queried.
        /// - Returns: EventLoopFuture<[Session]> to deliver result
        /// [apidoc]: https://developer.hashicorp.com/consul/api-docs/session#list-sessions
        ///
        public func list(inDatacenter datacenter: String? = nil) -> EventLoopFuture<[Session]> {
            var components = URLComponents()
            components.path = "/v1/session/list"

            var queryItems = [URLQueryItem]()
            if let datacenter, !datacenter.isEmpty {
                queryItems.append(URLQueryItem(name: "dc", value: datacenter))
            }

            if !queryItems.isEmpty {
                components.queryItems = queryItems
            }

            if let requestURI = components.string {
                let promise = impl.makePromise(of: [Session].self)
                impl.request(method: .PUT, uri: requestURI, body: nil, handler: ResponseHandler(promise))
                return promise.futureResult
            } else {
                return impl.makeFailedFuture(ConsulError.error("Can not build Consul API request string"))
            }
        }

        /// Renew existing sessions
        /// - Parameters
        ///    - id: session identifier
        ///    - datacenter: Specifies the datacenter to query. This will default to the datacenter of the agent being queried.
        /// - Returns: EventLoopFuture<Session> to deliver result
        /// [apidoc]: https://developer.hashicorp.com/consul/api-docs/session#renew-session
        ///
        public func renew(_ id: String, inDatacenter datacenter: String? = nil) -> EventLoopFuture<Session> {
            var components = URLComponents()
            components.path = "/v1/session/renew/\(id)"

            var queryItems = [URLQueryItem]()
            if let datacenter, !datacenter.isEmpty {
                queryItems.append(URLQueryItem(name: "dc", value: datacenter))
            }

            if !queryItems.isEmpty {
                components.queryItems = queryItems
            }

            if let requestURI = components.string {
                let promise = impl.makePromise(of: [Session].self)
                impl.request(method: .PUT, uri: requestURI, body: nil, handler: ResponseHandler(promise))
                return promise.futureResult.map { $0[0] }
            } else {
                return impl.makeFailedFuture(ConsulError.error("Can not build Consul API request string"))
            }
        }
    }

    public struct Poll {
        public let index: Int
        public let wait: String?
    }

    let impl: Impl

    public var serverHost: String { impl.serverHost }
    public var serverPort: Int { impl.serverPort }

    public let agent: AgentEndpoint
    public let catalog: CatalogEndpoint
    public let kv: KeyValueEndpoint
    public let session: SessionEndpoint

    public var logLevel: Logger.Level {
        get { impl.logger.logLevel }
        set { impl.logger.logLevel = newValue }
    }

    final class Impl: Sendable {
        let serverHost: String
        let serverPort: Int
        let eventLoopGroup: EventLoopGroup
        var logger: Logger

        init(_ serverHost: String, _ serverPort: Int, _ eventLoopGroup: EventLoopGroup) {
            self.serverHost = serverHost
            self.serverPort = serverPort
            self.eventLoopGroup = eventLoopGroup
            self.logger = Logger(label: "consul")
        }

        func request(method requestMethod: HTTPMethod, uri requestURI: String, body requestBody: ByteBuffer?, handler: some ConsulResponseHandler) {
            ClientBootstrap(group: eventLoopGroup)
                .channelInitializer { channel in
                    channel.pipeline.addHTTPClientHandlers(position: .first, leftOverBytesStrategy: .fireError).flatMap {
                        channel.pipeline.addHandler(HTTPHandler(self.serverHost,
                                                                self.serverPort,
                                                                requestMethod: requestMethod,
                                                                requestURI: requestURI,
                                                                requestBody: requestBody,
                                                                handler: handler,
                                                                self.logger))
                    }
                }
                .connect(host: serverHost, port: serverPort)
                .whenFailure { error in
                    let message = "Failed to connect to consul API @ \(self.serverHost):\(self.serverPort): \(error.localizedDescription)"
                    handler.fail(ConsulError.failedToConnect(message))
                }
        }

        func makePromise<T>(of type: T.Type = T.self, file: StaticString = #fileID, line: UInt = #line) -> EventLoopPromise<T> {
            return eventLoopGroup.next().makePromise(of: type, file: file, line: line)
        }

        func makeFailedFuture<T>(_ error: Error) -> EventLoopFuture<T> {
            return eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    private struct ResponseHandlerVoid: ConsulResponseHandler {
        private let promise: EventLoopPromise<Void>

        init(_ promise: EventLoopPromise<Void>) {
            self.promise = promise
        }

        func processResponse(_: ByteBuffer, withIndex _: Int?) {
            promise.succeed()
        }

        func fail(_ error: Error) {
            promise.fail(error)
        }
    }

    private struct ResponseHandler<T: Decodable & Sendable>: ConsulResponseHandler, Sendable {
        private let promise: EventLoopPromise<T>

        init(_ promise: EventLoopPromise<T>) {
            self.promise = promise
        }

        func processResponse(_ buffer: ByteBuffer, withIndex: Int?) {
            guard let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) else {
                fatalError("Internal error: bytes unexpectedly nil")
            }

            do {
                let value = try JSONDecoder().decode(T.self, from: Data(bytes))
                promise.succeed(value)
            } catch {
                guard let str = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) else {
                    fatalError("Internal error: str unexpectedly nil")
                }
                promise.fail(ConsulError.error("Consult response '\(str)' is not a valid JSON"))
            }
        }

        func fail(_ error: Error) {
            promise.fail(error)
        }
    }

    public init(host: String = defaultHost, port: Int = defaultPort) {
        // We use EventLoopFuture<> as a result for most calls,
        // the problem here is the 'future' is tied to particular event loop,
        // and from SwiftNIO point of view it is an error if we fill the 'future'
        // while the event loop it is tied to is stopped.
        // We create the 'future' for the particular event loop, but that future
        // will be notified from another event loop (which used by ClientBootstrap)
        // The only way to workaround that issue now is to use an event loop group
        // with only one event loop.
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        impl = Impl(host, port, eventLoopGroup)
        agent = AgentEndpoint(impl)
        catalog = CatalogEndpoint(impl)
        kv = KeyValueEndpoint(impl)
        session = SessionEndpoint(impl)
    }

    public func syncShutdown() throws {
        try impl.eventLoopGroup.syncShutdownGracefully()
    }
}

private class HTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let serverHost: String
    private let serverPort: Int
    private let requestMethod: HTTPMethod
    private let requestURI: String
    private let requestBody: ByteBuffer?
    private let handler: any ConsulResponseHandler
    private var responseBody: ByteBuffer?
    private var consulIndex: Int?
    private let logger: Logger

    init(_ serverHost: String, _ serverPort: Int, requestMethod: HTTPMethod, requestURI: String, requestBody: ByteBuffer?, handler: any ConsulResponseHandler, _ logger: Logger) {
        self.serverHost = serverHost
        self.serverPort = serverPort
        self.requestMethod = requestMethod
        self.requestURI = requestURI
        self.requestBody = requestBody
        self.responseBody = ByteBuffer()
        self.handler = handler
        self.logger = logger
    }

    func channelActive(context: ChannelHandlerContext) {
        logger.trace("\(logPrefix(context: context)): channelActive")

        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "\(serverHost):\(serverPort)")
        if let requestBody {
            headers.add(name: "Content-Length", value: "\(requestBody.readableBytes)")
        }

        let requestHead = HTTPRequestHead(version: .http1_1,
                                          method: requestMethod,
                                          uri: requestURI,
                                          headers: headers)

        context.write(wrapOutboundOut(.head(requestHead)), promise: nil)

        if let requestBody {
            context.write(wrapOutboundOut(.body(.byteBuffer(requestBody))), promise: nil)
        }

        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        logger.trace("\(logPrefix(context: context)): channelInactive")
        if responseBody != nil {
            handler.fail(ConsulError.error("Unexpected connection closed"))
            responseBody = nil
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        switch response {
        case let .head(responseHead):
            logger.trace("\(logPrefix(context: context)): channelRead: head: \(responseHead))")

            // store consul index from the header to propagate later to the response handler
            if let consulIndex = responseHead.headers.first(name: "X-Consul-Index") {
                self.consulIndex = Int(consulIndex)
            }

            if requestMethod == .PUT {
                if responseHead.status != .ok {
                    handler.fail(ConsulError.httpResponseError(responseHead.status))
                    responseBody = nil
                }
            }
        case var .body(buffer):
            logger.trace("\(logPrefix(context: context)): channelRead: body \(buffer.readableBytes) bytes")
            responseBody?.writeBuffer(&buffer)
        case .end:
            logger.trace("\(logPrefix(context: context)): channelRead: end, close channel")
            if let responseBody {
                handler.processResponse(responseBody, withIndex: consulIndex)
                self.responseBody = nil
            }
            context.close(promise: nil)
        }
    }

    private func logPrefix(context: ChannelHandlerContext) -> String {
        let addr = (context.remoteAddress != nil)
            ? context.remoteAddress!.description
            : "\(serverHost):\(serverPort)"
        return "\(addr)/\(requestURI)"
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.debug("\(logPrefix(context: context)): \(error)")
        if responseBody != nil {
            handler.fail(error)
            responseBody = nil
        }
        context.close(promise: nil)
    }
}
