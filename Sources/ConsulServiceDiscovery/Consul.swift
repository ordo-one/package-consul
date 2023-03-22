import ExtrasJSON
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

public enum ConsulError: Error {
    case failedToConnect(String)
    case error(String)
}

private protocol ConsulResponseHandler {
    func processResponse(_ buffer: ByteBuffer, withIndex: Int?)
    func fail(_ error: Error)
}

public class Consul {
    public static let defaultHost = "127.0.0.1"
    public static let defaultPort = 8_500

    public static var logger = Logger(label: "consul")

    public struct Poll {
        public let index: Int
        public let wait: String?
    }

    fileprivate let serverHost: String
    fileprivate let serverPort: Int

    private let eventLoopGroup: EventLoopGroup

    private func request(method requestMethod: HTTPMethod, uri requestURI: String, body requestBody: ByteBuffer?, handler: some ConsulResponseHandler) {
        Self.logger.debug("Request \(requestMethod) '\(requestURI)'")
        ClientBootstrap(group: eventLoopGroup)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers(position: .first, leftOverBytesStrategy: .fireError).flatMap {
                    channel.pipeline.addHandler(HTTPHandler(consul: self,
                                                            requestMethod: requestMethod,
                                                            requestURI: requestURI,
                                                            requestBody: requestBody,
                                                            handler: handler))
                }
            }
            .connect(host: serverHost, port: serverPort)
            .whenFailure { error in
                let message = "Failed to connect to consul API @ \(self.serverHost):\(self.serverPort): \(error.localizedDescription)"
                handler.fail(ConsulError.failedToConnect(message))
            }
    }

    public init(host: String = defaultHost, port: Int = defaultPort, with eventLoopGroup: EventLoopGroup) {
        serverHost = host
        serverPort = port
        self.eventLoopGroup = eventLoopGroup
    }

    /// Register a new service via local agent.
    /// - Parameter service: service to register
    /// - Returns: EventLoopFuture<Void> to deliver result
    /// [apidoc]: https://www.consul.io/api/agent/service.html#register-service
    ///
    public func agentRegisterService(_ service: Service) -> EventLoopFuture<Void> {
        struct ResponseHandler: ConsulResponseHandler {
            private let promise: EventLoopPromise<Void>
            private let service: Service

            init(_ promise: EventLoopPromise<Void>, _ service: Service) {
                self.promise = promise
                self.service = service
            }

            func processResponse(_: ByteBuffer, withIndex _: Int?) {
                promise.succeed()
            }

            func fail(_ error: Error) {
                promise.fail(error)
            }
        }

        let promise = eventLoopGroup.next().makePromise(of: Void.self)
        do {
            let data = try XJSONEncoder().encode(service)
            var requestBody = ByteBufferAllocator().buffer(capacity: data.count)
            requestBody.writeBytes(data)
            request(method: .PUT, uri: "/v1/agent/service/register", body: requestBody, handler: ResponseHandler(promise, service))
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
    public func agentDeregisterServiceID(_ serviceID: String) -> EventLoopFuture<Void> {
        struct ResponseHandler: ConsulResponseHandler {
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

        let promise = eventLoopGroup.next().makePromise(of: Void.self)
        request(method: .PUT, uri: "/v1/agent/service/deregister/\(serviceID)", body: nil, handler: ResponseHandler(promise))
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

            func processResponse(_ buffer: ByteBuffer, withIndex _: Int?) {
                do {
                    var buffer = buffer
                    let dict = try XJSONDecoder().decode([String: [String]].self, from: buffer.readBytes(length: buffer.readableBytes)!)
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
        if let requestURI = components.string {
            request(method: .GET, uri: requestURI, body: nil, handler: ResponseHandler(promise))
        } else {
            promise.fail(ConsulError.error("Can not build Consul API request string"))
        }
        return promise.futureResult
    }

    /// Returns the nodes providing a service in a given datacenter.
    /// - Parameters
    ///    - datacenter: Specifies the datacenter to query. This will default to the datacenter of the agent being queried.
    ///    - serviceName: Specifies the name of the service for which to list nodes.
    /// - Returns: EventLoopFuture<[NodeService]> to deliver result
    /// [apidoc]: https://developer.hashicorp.com/consul/api-docs/catalog#list-nodes-for-service
    ///
    public func catalogNodes(inDatacenter datacenter: String = "",
                             withService serviceName: String,
                             poll: Poll? = nil) -> EventLoopFuture<(Int, [NodeService])> {
        struct ResponseHandler: ConsulResponseHandler {
            private let promise: EventLoopPromise<(Int, [NodeService])>

            init(_ promise: EventLoopPromise<(Int, [NodeService])>) {
                self.promise = promise
            }

            func processResponse(_ buffer: ByteBuffer, withIndex: Int?) {
                guard let withIndex else {
                    promise.fail(ConsulError.error("Internal error: missing index"))
                    return
                }

                do {
                    var buffer = buffer
                    let services = try XJSONDecoder().decode([NodeService].self, from: buffer.readBytes(length: buffer.readableBytes)!)
                    promise.succeed((withIndex, services))
                } catch {
                    promise.fail(error)
                }
            }

            func fail(_ error: Error) {
                promise.fail(error)
            }
        }

        var queryItems: [URLQueryItem] = []

        if !datacenter.isEmpty {
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

        let promise = eventLoopGroup.next().makePromise(of: (Int, [NodeService]).self)
        if let requestURI = components.string {
            request(method: .GET, uri: requestURI, body: nil, handler: ResponseHandler(promise))
        } else {
            promise.fail(ConsulError.error("Can not build Consul API request string"))
        }
        return promise.futureResult
    }
}

private class HTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let consul: Consul
    private let requestMethod: HTTPMethod
    private let requestURI: String
    private let requestBody: ByteBuffer?
    private let handler: any ConsulResponseHandler
    private var responseBody: ByteBuffer?
    private var consulIndex: Int?

    init(consul: Consul, requestMethod: HTTPMethod, requestURI: String, requestBody: ByteBuffer?, handler: any ConsulResponseHandler) {
        self.consul = consul
        self.requestMethod = requestMethod
        self.requestURI = requestURI
        self.requestBody = requestBody
        responseBody = ByteBuffer()
        self.handler = handler
    }

    func channelActive(context: ChannelHandlerContext) {
        Consul.logger.debug("\(context.remoteAddress!): channelActive")

        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "\(consul.serverHost):\(consul.serverPort)")

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
        Consul.logger.debug("\(context.remoteAddress!): channelInactive")
        if responseBody != nil {
            handler.fail(ConsulError.error("Unexpected connection closed"))
            responseBody = nil
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        switch response {
        case let .head(responseHead):
            Consul.logger.debug("\(context.remoteAddress!): channelRead: head: \(responseHead))")

            // store consul index from the header to propagate late to the response handler
            if let consulIndex = responseHead.headers.first(name: "X-Consul-Index") {
                self.consulIndex = Int(consulIndex)
            }

            if requestMethod == .PUT {
                // body not expected
                if responseHead.status == .ok {
                    handler.processResponse(ByteBuffer(), withIndex: consulIndex)
                } else {
                    handler.fail(ConsulError.error("\(responseHead.status)"))
                }
                responseBody = nil
            }
        case var .body(buffer):
            Consul.logger.debug("\(context.remoteAddress!): channelRead: body \(buffer.readableBytes) bytes")
            responseBody?.writeBuffer(&buffer)
        case .end:
            Consul.logger.debug("\(context.remoteAddress!): channelRead: end, close channel")
            if let responseBody {
                handler.processResponse(responseBody, withIndex: consulIndex)
                self.responseBody = nil
            }
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Consul.logger.debug("\(context.remoteAddress!): \(error)")
        if responseBody != nil {
            handler.fail(error)
            responseBody = nil
        }
        context.close(promise: nil)
    }
}
