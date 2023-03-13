import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

var logger = Logger(label: "consul")

public enum ConsulError: Error {
    case failedToConnect(String)
    case error(String)
}

private protocol ConsulResponseHandler {
    func process(response buffer: ByteBuffer)
    func fail(_ error: Error)
}

public class Consul {
    public static let defaultHost = "127.0.0.1"
    public static let defaultPort = 8500

    public struct AgentService: Hashable, Encodable {
        public let ID: String
        public let Address: String
        public let Name: String
        public let Port: Int
    }

    public struct NodeService: Hashable, Decodable {
        public let Address: String
        public let Datacenter: String
        public let ID: String
        public let Node: String
        public let ServiceID: String
        public let ServiceName: String
        public let ServicePort: Int
    }

    private let serverHost: String
    private let serverPort: Int

    private let eventLoopGroup: MultiThreadedEventLoopGroup

    private class HTTPHandler: ChannelInboundHandler {
        public typealias InboundIn = HTTPClientResponsePart
        public typealias OutboundOut = HTTPClientRequestPart

        private let consul: Consul
        private let requestMethod: HTTPMethod
        private let requestURI: String
        private let requestBody: ByteBuffer?
        private let handler: any ConsulResponseHandler
        private var handlerCalled: Bool

        init(_ consul: Consul, _ requestMethod: HTTPMethod, _ requestURI: String, _ requestBody: ByteBuffer?, _ handler: any ConsulResponseHandler) {
            self.consul = consul
            self.requestMethod = requestMethod
            self.requestURI = requestURI
            self.requestBody = requestBody
            self.handler = handler
            handlerCalled = false
        }

        public func channelActive(context: ChannelHandlerContext) {
            logger.debug("\(context.remoteAddress!): channelActive")

            var headers = HTTPHeaders()
            headers.add(name: "Host", value: "\(consul.serverHost):\(consul.serverPort)")

            let requestHead = HTTPRequestHead(version: .http1_1,
                                              method: requestMethod,
                                              uri: requestURI,
                                              headers: headers)

            context.write(wrapOutboundOut(.head(requestHead)), promise: nil)

            if let requestBody = requestBody {
                context.write(wrapOutboundOut(.body(.byteBuffer(requestBody))), promise: nil)
            }

            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }

        public func channelInactive(context: ChannelHandlerContext) {
            logger.debug("\(context.remoteAddress!): channelInactive")
            if !handlerCalled {
                handler.fail(ConsulError.error("connection closed"))
                handlerCalled = true
            }
        }

        public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let response = unwrapInboundIn(data)
            switch response {
            case let .head(responseHead):
                logger.debug("\(context.remoteAddress!): channelRead: head: \(responseHead))")
                if requestMethod == .PUT {
                    // body not expected
                    if responseHead.status == .ok {
                        handler.process(response: ByteBuffer())
                    } else {
                        handler.fail(ConsulError.error("\(responseHead.status)"))
                    }
                    handlerCalled = true
                }
            case let .body(byteBuffer):
                logger.debug("\(context.remoteAddress!): channelRead: body \(String(buffer: byteBuffer))")
                if !handlerCalled {
                    handler.process(response: byteBuffer)
                    handlerCalled = true
                }
            case .end:
                logger.debug("\(context.remoteAddress!): channelRead: end, close channel")
                context.close(promise: nil)
            }
        }

        public func errorCaught(context: ChannelHandlerContext, error: Error) {
            logger.debug("\(context.remoteAddress!): \(error)")
            if !handlerCalled {
                handler.fail(error)
                handlerCalled = true
            }
            context.close(promise: nil)
        }
    }

    private func request<Handler: ConsulResponseHandler>(_ requestMethod: HTTPMethod, _ requestURI: String, _ requestBody: ByteBuffer?, _ handler: Handler) {
        _ = ClientBootstrap(group: eventLoopGroup)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers(position: .first, leftOverBytesStrategy: .fireError).flatMap {
                    channel.pipeline.addHandler(HTTPHandler(self, requestMethod, requestURI, requestBody, handler))
                }
            }
            .connect(host: serverHost, port: serverPort)
            .whenFailure { error in
                let message = "Failed to connect to consul API @ \(self.serverHost):\(self.serverPort): \(error.localizedDescription)"
                handler.fail(ConsulError.failedToConnect(message))
            }
    }

    public init(host: String = defaultHost, port: Int = defaultPort, with eventLoopGroup: MultiThreadedEventLoopGroup) {
        serverHost = host
        serverPort = port
        self.eventLoopGroup = eventLoopGroup
    }

    /// Register a new service via local agent.
    /// - Parameter service: service to register
    /// - Returns: EventLoopFuture<Void> to deliver result
    /// [apidoc]: https://www.consul.io/api/agent/service.html#register-service
    ///
    public func agentRegister(service: AgentService) -> EventLoopFuture<Void> {
        struct ResponseHandler: ConsulResponseHandler {
            private let promise: EventLoopPromise<Void>
            private let service: AgentService

            init(_ promise: EventLoopPromise<Void>, _ service: AgentService) {
                self.promise = promise
                self.service = service
            }

            func process(response _: ByteBuffer) {
                promise.succeed()
            }

            func fail(_ error: Error) {
                promise.fail(error)
            }
        }

        let promise = eventLoopGroup.next().makePromise(of: Void.self)
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(service)
            var requestBody = ByteBufferAllocator().buffer(capacity: data.count)
            requestBody.writeBytes(data)
            request(.PUT, "/v1/agent/service/register", requestBody, ResponseHandler(promise, service))
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
    public func agentDeregister(serviceID: String) -> EventLoopFuture<Void> {
        struct ResponseHandler: ConsulResponseHandler {
            private let promise: EventLoopPromise<Void>

            init(_ promise: EventLoopPromise<Void>) {
                self.promise = promise
            }

            func process(response _: ByteBuffer) {
                promise.succeed()
            }

            func fail(_ error: Error) {
                promise.fail(error)
            }
        }

        let promise = eventLoopGroup.next().makePromise(of: Void.self)
        request(.PUT, "/v1/agent/service/deregister/\(serviceID)", nil, ResponseHandler(promise))
        return promise.futureResult
    }

    /// Returns the services registered in a given datacenter.
    /// - Parameter datacenter: Specifies the datacenter to query. This will default to the datacenter of the agent being queried.
    /// - Returns: EventLoopFuture<[String]> to deliver result
    /// [apidoc]: https://developer.hashicorp.com/consul/api-docs/catalog#list-services
    ///
    public func catalogServices(inDatacenter datacenter: String = "") -> EventLoopFuture<[String]> {
        struct ResponseHandler: ConsulResponseHandler {
            private let promise: EventLoopPromise<[String]>

            init(_ promise: EventLoopPromise<[String]>) {
                self.promise = promise
            }

            func process(response buffer: ByteBuffer) {
                do {
                    let decoder = JSONDecoder()
                    let data = buffer.withUnsafeReadableBytes { ptr in
                        Data(bytes: UnsafeMutableRawPointer(mutating: ptr.baseAddress!),
                             count: ptr.count)
                    }
                    let dict = try decoder.decode([String: [String]].self, from: data)
                    promise.succeed(Array(dict.keys))
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
        if !datacenter.isEmpty {
            components.queryItems = [URLQueryItem(name: "dc", value: datacenter)]
        }

        let promise = eventLoopGroup.next().makePromise(of: [String].self)
        request(.GET, components.string!, nil, ResponseHandler(promise))
        return promise.futureResult
    }

    /// Returns the nodes providing a service in a given datacenter.
    /// - Parameters
    ///    - datacenter: Specifies the datacenter to query. This will default to the datacenter of the agent being queried.
    ///    - serviceName: Specifies the name of the service for which to list nodes.
    /// - Returns: EventLoopFuture<[NodeService]> to deliver result
    /// [apidoc]: https://developer.hashicorp.com/consul/api-docs/catalog#list-nodes-for-service
    ///
    public func catalogNodes(inDatacenter datacenter: String = "", withService serviceName: String) -> EventLoopFuture<[NodeService]> {
        struct ResponseHandler: ConsulResponseHandler {
            private let promise: EventLoopPromise<[NodeService]>

            init(_ promise: EventLoopPromise<[NodeService]>) {
                self.promise = promise
            }

            func process(response buffer: ByteBuffer) {
                do {
                    let decoder = JSONDecoder()
                    let data = buffer.withUnsafeReadableBytes { ptr in
                        Data(bytes: UnsafeMutableRawPointer(mutating: ptr.baseAddress!),
                             count: ptr.count)
                    }
                    let services = try decoder.decode([NodeService].self, from: data)
                    promise.succeed(services)
                } catch {
                    promise.fail(error)
                }
            }

            func fail(_ error: Error) {
                promise.fail(error)
            }
        }

        var components = URLComponents()
        components.path = "/v1/catalog/service/\(serviceName)"
        if !datacenter.isEmpty {
            components.queryItems = [URLQueryItem(name: "dc", value: datacenter)]
        }

        let promise = eventLoopGroup.next().makePromise(of: [NodeService].self)
        request(.GET, "/v1/catalog/service/\(serviceName)", nil, ResponseHandler(promise))
        return promise.futureResult
    }
}
