import XCTest
import Foundation
import NIOCore
import NIOPosix
@testable import SwiftTorrent

final class TrackerTests: XCTestCase {
    func testParseCompactPeers() throws {
        // Create a mock bencoded tracker response with compact peers
        let encoder = BencodeEncoder()

        // 6 bytes: 192.168.1.1:6881
        var peerData = Data()
        peerData.append(contentsOf: [192, 168, 1, 1])
        peerData.append(contentsOf: UInt16(6881).bigEndianBytes)
        // 6 bytes: 10.0.0.1:8080
        peerData.append(contentsOf: [10, 0, 0, 1])
        peerData.append(contentsOf: UInt16(8080).bigEndianBytes)

        let response: BencodeValue = .dictionary([
            (key: Data("complete".utf8), value: .integer(10)),
            (key: Data("incomplete".utf8), value: .integer(5)),
            (key: Data("interval".utf8), value: .integer(1800)),
            (key: Data("peers".utf8), value: .string(peerData)),
        ])

        let data = encoder.encode(response)
        let decoded = try BencodeDecoder().decode(data)

        // Verify structure
        XCTAssertEqual(decoded["interval"]?.integerValue, 1800)
        XCTAssertEqual(decoded["complete"]?.integerValue, 10)
        XCTAssertEqual(decoded["peers"]?.stringValue?.count, 12)
    }

    func testTrackerErrorResponse() throws {
        let encoder = BencodeEncoder()
        let response: BencodeValue = .dictionary([
            (key: Data("failure reason".utf8), value: .string(Data("Torrent not found".utf8))),
        ])
        let data = encoder.encode(response)
        let decoded = try BencodeDecoder().decode(data)
        XCTAssertEqual(decoded["failure reason"]?.utf8String, "Torrent not found")
    }

    func testUDPTrackerAnnounceSupportsIPv6LiteralTrackers() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        addTeardownBlock {
            try await group.shutdownGracefully()
        }

        let server = try await DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(LoopbackUDPTrackerHandler())
            }
            .bind(host: "::1", port: 0)
            .get()
        addTeardownBlock {
            try await server.close().get()
        }

        let tracker = UDPTracker(host: "::1", port: server.localAddress!.port!, group: group)
        let response = try await tracker.announce(params: AnnounceParams(
            infoHash: InfoHash(bytes: Data(repeating: 0xaa, count: 20)),
            peerID: Data("-ST0001-test-peer!!!".utf8),
            port: 6881,
            left: 0,
            event: "started"
        ))

        XCTAssertEqual(response.interval, 60)
        XCTAssertEqual(response.seeders, 1)
        XCTAssertEqual(response.leechers, 0)
        XCTAssertEqual(response.peers.count, 1)
        XCTAssertEqual(response.peers.first?.0, "127.0.0.1")
        XCTAssertEqual(response.peers.first?.1, 6881)
    }

    func testTrackerManagerContinuesPastEmptySuccessfulAnnounce() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        addTeardownBlock {
            try await group.shutdownGracefully()
        }

        let emptyServer = try await DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(LoopbackUDPTrackerHandler(peers: []))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        addTeardownBlock {
            try await emptyServer.close().get()
        }

        let peerServer = try await DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(LoopbackUDPTrackerHandler(peers: [("127.0.0.1", 51413)]))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        addTeardownBlock {
            try await peerServer.close().get()
        }

        let trackerManager = TrackerManager(
            tiers: [
                ["udp://127.0.0.1:\(emptyServer.localAddress!.port!)/announce"],
                ["udp://127.0.0.1:\(peerServer.localAddress!.port!)/announce"],
            ],
            group: group
        )
        let response = try await trackerManager.announce(params: AnnounceParams(
            infoHash: InfoHash(bytes: Data(repeating: 0xaa, count: 20)),
            peerID: Data("-ST0001-test-peer!!!".utf8),
            port: 6881,
            left: 0,
            event: "started"
        ))

        XCTAssertEqual(response.peers.count, 1)
        XCTAssertEqual(response.peers.first?.0, "127.0.0.1")
        XCTAssertEqual(response.peers.first?.1, 51413)
    }

    func testTrackerManagerAggregatesPeersFromAllSuccessfulTrackers() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        addTeardownBlock {
            try await group.shutdownGracefully()
        }

        let firstServer = try await DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(LoopbackUDPTrackerHandler(peers: [("127.0.0.1", 51413)]))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        addTeardownBlock {
            try await firstServer.close().get()
        }

        let secondServer = try await DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(LoopbackUDPTrackerHandler(peers: [
                    ("127.0.0.1", 51413),
                    ("127.0.0.2", 51414),
                ]))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        addTeardownBlock {
            try await secondServer.close().get()
        }

        let trackerManager = TrackerManager(
            tiers: [
                ["udp://127.0.0.1:\(firstServer.localAddress!.port!)/announce"],
                ["udp://127.0.0.1:\(secondServer.localAddress!.port!)/announce"],
            ],
            group: group
        )
        let response = try await trackerManager.announce(params: AnnounceParams(
            infoHash: InfoHash(bytes: Data(repeating: 0xaa, count: 20)),
            peerID: Data("-ST0001-test-peer!!!".utf8),
            port: 49_889,
            left: 0,
            event: "started"
        ))

        XCTAssertEqual(response.peers.count, 2)
        XCTAssertTrue(response.peers.contains { $0.0 == "127.0.0.1" && $0.1 == 51413 })
        XCTAssertTrue(response.peers.contains { $0.0 == "127.0.0.2" && $0.1 == 51414 })
    }
}

private final class LoopbackUDPTrackerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let connectionID: UInt64 = 0x1122334455667788
    private let peers: [(String, UInt16)]

    init(peers: [(String, UInt16)] = [("127.0.0.1", 6881)]) {
        self.peers = peers
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var request = envelope.data
        guard let bytes = request.readBytes(length: request.readableBytes) else {
            return
        }

        let requestData = Data(bytes)
        guard requestData.count >= 16 else {
            return
        }

        let action = requestData.readUInt32BE(at: 8)
        let transactionID = requestData.readUInt32BE(at: 12)
        let response: Data

        switch action {
        case 0:
            response = connectResponse(transactionID: transactionID)
        case 1:
            response = announceResponse(transactionID: transactionID)
        default:
            return
        }

        var buffer = context.channel.allocator.buffer(capacity: response.count)
        buffer.writeBytes(response)
        let responseEnvelope = AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: buffer)
        context.writeAndFlush(wrapOutboundOut(responseEnvelope), promise: nil)
    }

    private func connectResponse(transactionID: UInt32) -> Data {
        var response = Data()
        response.append(contentsOf: UInt32(0).bigEndianBytes)
        response.append(contentsOf: transactionID.bigEndianBytes)
        response.append(contentsOf: connectionID.bigEndianBytes)
        return response
    }

    private func announceResponse(transactionID: UInt32) -> Data {
        var response = Data()
        response.append(contentsOf: UInt32(1).bigEndianBytes)
        response.append(contentsOf: transactionID.bigEndianBytes)
        response.append(contentsOf: UInt32(60).bigEndianBytes)
        response.append(contentsOf: UInt32(0).bigEndianBytes)
        response.append(contentsOf: UInt32(peers.count).bigEndianBytes)
        for (address, port) in peers {
            let octets = address.split(separator: ".").compactMap { UInt8($0) }
            guard octets.count == 4 else {
                continue
            }
            response.append(contentsOf: octets)
            response.append(contentsOf: port.bigEndianBytes)
        }
        return response
    }
}
