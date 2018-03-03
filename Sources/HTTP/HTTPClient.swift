import Foundation

public final class HTTPClient: HTTPResponder {
    private let handler: HTTPClientHandler
    private let bootstrap: ClientBootstrap

    private init(handler: HTTPClientHandler, bootstrap: ClientBootstrap) {
        self.handler = handler
        self.bootstrap = bootstrap
    }

    public static func connect(hostname: String, port: Int) -> Future<HTTPClient> {
        let group = MultiThreadedEventLoopGroup(numThreads: 1) // System.coreCount

        let handler = HTTPClientHandler()
        let bootstrap = ClientBootstrap(group: group)
            // Enable SO_REUSEADDR.
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelInitializer { channel in
                return channel.pipeline.addHTTPClientHandlers().then {
                    channel.pipeline.add(handler: handler)
                }
            }

        return bootstrap.connect(host: hostname, port: port).map(to: HTTPClient.self) { _ in
            return .init(handler: handler, bootstrap: bootstrap)
        }
    }

    public func respond(to request: HTTPRequest) -> Future<HTTPResponse> {
        return handler.enqueue(request)
    }
}

enum HTTPClientState {
    case ready
    case parsingBody(HTTPResponseHead, Data?)
}

final class HTTPClientHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private var waitingCtx: ChannelHandlerContext?
    private var waitingReq: HTTPRequest?
    private var waitingRes: Promise<HTTPResponse>?
    private var state: HTTPClientState

    init() {
        self.state = .ready
    }

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let req = unwrapInboundIn(data)
        switch req {
        case .head(let head):
            switch state {
            case .ready: state = .parsingBody(head, nil)
            case .parsingBody: fatalError()
            }
        case .body(var body):
            switch state {
            case .ready: fatalError()
            case .parsingBody(let head, let existingData):
                let data: Data
                if var existing = existingData {
                    existing += body.readData(length: body.readableBytes) ?? Data()
                    data = existing
                } else {
                    data = body.readData(length: body.readableBytes) ?? Data()
                }
                state = .parsingBody(head, data)
            }
        case .end(let tailHeaders):
            assert(tailHeaders == nil)
            switch state {
            case .ready: fatalError()
            case .parsingBody(let head, let data):
                let res = HTTPResponse(
                    status: head.status,
                    version: head.version,
                    headers: head.headers,
                    body: data.flatMap { HTTPBody(data: $0) } ?? HTTPBody(),
                    on: wrap(ctx.eventLoop)
                )
                waitingRes!.succeed(result: res)
                waitingRes = nil
            }
        }
    }

    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        if let res = waitingRes {
            res.fail(error: error)
            waitingRes = nil
        } else {
            print("error: ", error)
        }

        // As we are not really interested getting notified on success or failure we just pass nil as promise to
        // reduce allocations.
        ctx.close(promise: nil)
    }

    func channelActive(ctx: ChannelHandlerContext) {
        if let req = waitingReq {
            waitingReq = nil
            write(req, to: ctx)
        } else {
            assert(waitingCtx == nil)
            waitingCtx = ctx
        }
    }

    func enqueue(_ req: HTTPRequest) -> Future<HTTPResponse> {
        assert(waitingRes == nil)
        let promise = req.eventLoop.newPromise(HTTPResponse.self)
        waitingRes = promise
        if let ctx = waitingCtx {
            waitingCtx = nil
            write(req, to: ctx)
        } else {
            assert(waitingReq == nil)
            waitingReq = req
        }
        return promise.futureResult
    }

    func write(_ req: HTTPRequest, to ctx: ChannelHandlerContext) {
        var headers = req.headers
        if let contentLength = req.body.count {
            headers.replaceOrAdd(name: .contentLength, value: contentLength.description)
        } else {
            headers.replaceOrAdd(name: .contentLength, value: "0")
        }
        var httpHead = HTTPRequestHead(version: req.version, method: req.method, uri: req.url.path)
        httpHead.headers = headers
        ctx.write(wrapOutboundOut(.head(httpHead)), promise: nil)
        if let data = req.body.data {
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.write(bytes: data)
            ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }
}
