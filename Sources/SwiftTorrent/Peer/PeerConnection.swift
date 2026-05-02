import Foundation
import NIOCore
import NIOPosix
import NIOExtras

/// Manages a single peer TCP connection using SwiftNIO.
public final class PeerConnection: @unchecked Sendable {
    public let address: String
    public let port: UInt16

    private var _channel: Channel?
    private let lock = NSLock()
    private let infoHash: Data
    private let peerID: Data

    public var onMessage: (@Sendable (PeerMessage) -> Void)?
    public var onDisconnect: (@Sendable () -> Void)?
    public private(set) var remotePeerID: Data?
    public private(set) var supportsExtensions: Bool = false

    public init(address: String, port: UInt16, infoHash: Data, peerID: Data) {
        self.address = address
        self.port = port
        self.infoHash = infoHash
        self.peerID = peerID
    }

    private func setChannel(_ ch: Channel) {
        lock.lock()
        _channel = ch
        lock.unlock()
    }

    private func getChannel() -> Channel? {
        lock.lock()
        defer { lock.unlock() }
        return _channel
    }

    public func connect(on group: EventLoopGroup) async throws -> Channel {
        let onMsg = self.onMessage
        let onDisc = self.onDisconnect
        let handshakeState = PeerHandshakeState()

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                let decoderHandler = ByteToMessageHandler(PeerMessageDecoder(handshakeState: handshakeState))
                let messageHandler = PeerMessageHandler(onMessage: onMsg, onDisconnect: onDisc)
                do {
                    try channel.pipeline.syncOperations.addHandlers(decoderHandler, messageHandler, PeerMessageEncoder())
                    return channel.eventLoop.makeSucceededFuture(())
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        let ch = try await bootstrap.connect(host: address, port: Int(port)).get()

        setChannel(ch)

        // Send handshake as raw bytes (before the encoder is in the pipeline)
        let handshake = Handshake(infoHash: infoHash, peerID: peerID)
        try await ch.writeAndFlush(PeerOutbound.raw(handshake.encode())).get()

        do {
            try await handshakeState.waitForHandshake(timeout: .seconds(5))
        } catch {
            try? await ch.close().get()
            throw error
        }

        // Store remote handshake info
        self.remotePeerID = handshakeState.remotePeerID
        self.supportsExtensions = handshakeState.supportsExtensions

        return ch
    }

    public func send(_ message: PeerMessage) async throws {
        guard let ch = getChannel() else {
            throw PeerConnectionError.notConnected
        }
        try await ch.writeAndFlush(PeerOutbound.message(message)).get()
    }

    public func close() async throws {
        guard let ch = getChannel() else { return }
        try await ch.close().get()
    }
}

public enum PeerConnectionError: Error {
    case notConnected
    case handshakeFailed
}

// MARK: - NIO Channel Handlers

private final class PeerHandshakeState: @unchecked Sendable {
    private let lock = NSLock()
    private var _remotePeerID: Data?
    private var _supportsExtensions = false
    private var handshakeContinuation: CheckedContinuation<Void, any Error>?

    var remotePeerID: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _remotePeerID
    }

    var supportsExtensions: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _supportsExtensions
    }

    func update(remotePeerID: Data, supportsExtensions: Bool) {
        lock.lock()
        _remotePeerID = remotePeerID
        _supportsExtensions = supportsExtensions
        let continuation = handshakeContinuation
        handshakeContinuation = nil
        lock.unlock()
        continuation?.resume(returning: ())
    }

    func waitForHandshake(timeout: Duration) async throws {
        if remotePeerID != nil { return }

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.resumeHandshakeWaiterIfNeeded(throwing: PeerConnectionError.handshakeFailed)
        }

        defer { timeoutTask.cancel() }
        try await waitForHandshake()
    }

    private func waitForHandshake() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if _remotePeerID != nil {
                lock.unlock()
                continuation.resume(returning: ())
                return
            }

            handshakeContinuation = continuation
            lock.unlock()
        }
    }

    private func resumeHandshakeWaiterIfNeeded(throwing error: any Error) {
        lock.lock()
        let continuation = handshakeContinuation
        handshakeContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

/// Decodes peer wire protocol messages from byte stream.
final class PeerMessageDecoder: ByteToMessageDecoder {
    typealias InboundOut = PeerMessage

    private var handshakeReceived = false

    private let handshakeState: PeerHandshakeState

    fileprivate init(handshakeState: PeerHandshakeState) {
        self.handshakeState = handshakeState
    }

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if !handshakeReceived {
            guard buffer.readableBytes >= Handshake.length else { return .needMoreData }
            guard let bytes = buffer.readBytes(length: Handshake.length) else { return .needMoreData }
            let handshake = try Handshake.decode(from: Data(bytes))
            handshakeState.update(
                remotePeerID: handshake.peerID,
                supportsExtensions: (handshake.reserved[5] & 0x10) != 0
            )
            handshakeReceived = true
            return .continue
        }

        guard buffer.readableBytes >= 4 else { return .needMoreData }
        let lengthBytes = buffer.getBytes(at: buffer.readerIndex, length: 4)!
        let length = Data(lengthBytes).readUInt32BE(at: 0)

        if length == 0 {
            buffer.moveReaderIndex(forwardBy: 4)
            context.fireChannelRead(wrapInboundOut(.keepAlive))
            return .continue
        }

        guard buffer.readableBytes >= 4 + Int(length) else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 4)
        guard let payload = buffer.readBytes(length: Int(length)) else { return .needMoreData }
        let message = try PeerMessage.decode(from: Data(payload))
        context.fireChannelRead(wrapInboundOut(message))
        return .continue
    }
}

/// Receives decoded PeerMessage and calls the callback.
final class PeerMessageHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = PeerMessage

    private let onMessage: (@Sendable (PeerMessage) -> Void)?
    private let onDisconnect: (@Sendable () -> Void)?

    init(onMessage: (@Sendable (PeerMessage) -> Void)?, onDisconnect: (@Sendable () -> Void)?) {
        self.onMessage = onMessage
        self.onDisconnect = onDisconnect
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        onMessage?(message)
    }

    func channelInactive(context: ChannelHandlerContext) {
        onDisconnect?()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Encodes peer wire protocol messages to byte stream.
fileprivate enum PeerOutbound: Sendable {
    case raw(Data)
    case message(PeerMessage)
}

fileprivate final class PeerMessageEncoder: ChannelOutboundHandler, Sendable {
    typealias OutboundIn = PeerOutbound
    typealias OutboundOut = ByteBuffer

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let outbound = unwrapOutboundIn(data)
        let encoded: Data
        switch outbound {
        case .raw(let bytes):
            encoded = bytes
        case .message(let msg):
            encoded = msg.encode()
        }
        var buffer = context.channel.allocator.buffer(capacity: encoded.count)
        buffer.writeBytes(encoded)
        context.write(wrapOutboundOut(buffer), promise: promise)
    }
}
