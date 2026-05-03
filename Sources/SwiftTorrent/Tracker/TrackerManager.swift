import Foundation
import NIOCore

/// Coordinates multiple trackers with tier support.
public actor TrackerManager {
    private let tiers: [[String]]
    private let group: EventLoopGroup
    private var lastResponse: AnnounceResponse?
    private var announceInterval: Int = 1800

    public init(tiers: [[String]], group: EventLoopGroup) {
        self.tiers = tiers
        self.group = group
    }

    /// Convenience: create from TorrentInfo.
    public init(info: TorrentInfo, group: EventLoopGroup) {
        var tiers = info.announceList
        if tiers.isEmpty, let url = info.announceURL {
            tiers = [[url]]
        }
        self.tiers = tiers
        self.group = group
    }

    /// Announce to all tracker tiers and aggregate peer results.
    public func announce(params: AnnounceParams) async throws -> AnnounceResponse {
        var successfulResponses: [AnnounceResponse] = []
        let trackerURLs = tiers.flatMap { $0 }
        let eventLoopGroup = SendableEventLoopGroup(group)

        await withTaskGroup(of: AnnounceResponse?.self) { taskGroup in
            for urlString in trackerURLs {
                taskGroup.addTask {
                    try? await Self.announce(
                        urlString: urlString,
                        params: params,
                        group: eventLoopGroup.value
                    )
                }
            }

            for await response in taskGroup {
                if let response {
                    successfulResponses.append(response)
                }
            }
        }

        guard successfulResponses.isEmpty == false else {
            throw TrackerError.connectionFailed
        }

        var seenPeers = Set<String>()
        var peers: [(String, UInt16)] = []
        var seeders = 0
        var leechers = 0
        var interval = successfulResponses[0].interval

        for response in successfulResponses {
            interval = min(interval, response.interval)
            seeders += response.seeders
            leechers += response.leechers
            for peer in response.peers {
                let key = "\(peer.0):\(peer.1)"
                if seenPeers.insert(key).inserted {
                    peers.append(peer)
                }
            }
        }

        let combined = AnnounceResponse(
            interval: interval,
            seeders: seeders,
            leechers: leechers,
            peers: peers
        )
        lastResponse = combined
        announceInterval = combined.interval
        return combined
    }

    public func getInterval() -> Int {
        announceInterval
    }

    private static func announce(urlString: String, params: AnnounceParams, group: EventLoopGroup) async throws -> AnnounceResponse {
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            let tracker = HTTPTracker(announceURL: urlString)
            return try await tracker.announce(params: params)
        }

        if urlString.hasPrefix("udp://") {
            guard let components = URLComponents(string: urlString),
                  let host = components.host,
                  let port = components.port else {
                throw TrackerError.invalidURL
            }
            let tracker = UDPTracker(host: host, port: port, group: group)
            return try await tracker.announce(params: params)
        }

        throw TrackerError.invalidURL
    }
}

private struct SendableEventLoopGroup: @unchecked Sendable {
    let value: EventLoopGroup

    init(_ value: EventLoopGroup) {
        self.value = value
    }
}
