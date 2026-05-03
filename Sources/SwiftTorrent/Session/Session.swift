import Foundation
import NIOCore
import NIOPosix

/// Top-level controller for managing torrents.
public actor Session {
    private var settings: SessionSettings
    private var torrents: [InfoHash: TorrentHandle] = [:]
    private let group: MultiThreadedEventLoopGroup
    private var dhtNode: DHTNode?
    private var dhtPeerDiscoveryTask: Task<Void, Never>?
    private let alertContinuation: AsyncStream<any Alert>.Continuation
    public let alerts: AsyncStream<any Alert>

    public init(settings: SessionSettings = SessionSettings()) {
        self.settings = settings
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let (stream, continuation) = AsyncStream<any Alert>.makeStream()
        self.alerts = stream
        self.alertContinuation = continuation
    }

    /// Add a torrent to the session.
    public func addTorrent(_ params: AddTorrentParams) async throws -> TorrentHandle {
        guard let hash = params.infoHash else {
            throw AddTorrentError.noInfoHash
        }
        if let existing = torrents[hash] {
            return existing
        }

        let handle = TorrentHandle(params: params, settings: settings, group: group)
        await handle.finishInitialization()
        torrents[hash] = handle

        alertContinuation.yield(TorrentAddedAlert(
            infoHash: hash,
            name: params.torrentInfo?.name ?? params.magnetLink?.displayName ?? "Unknown"
        ))

        if !params.paused {
            try await handle.start()
        }
        if let dhtNode, params.paused == false {
            await discoverPeers(for: handle, using: dhtNode)
        }

        return handle
    }

    /// Remove a torrent from the session.
    public func removeTorrent(_ infoHash: InfoHash, deleteFiles: Bool = false) async {
        guard let handle = torrents.removeValue(forKey: infoHash) else { return }
        await handle.pause()

        if deleteFiles {
            let _ = await handle.status()
            // Delete files from disk
            let path = settings.savePath
            try? FileManager.default.removeItem(atPath: path)
        }

        alertContinuation.yield(TorrentRemovedAlert(infoHash: infoHash))
    }

    /// Get a torrent handle by info hash.
    public func torrent(for infoHash: InfoHash) -> TorrentHandle? {
        torrents[infoHash]
    }

    /// Get all torrent handles.
    public func allTorrents() -> [TorrentHandle] {
        Array(torrents.values)
    }

    /// Get status of all torrents.
    public func allStatus() async -> [TorrentStatus] {
        var statuses: [TorrentStatus] = []
        for handle in torrents.values {
            statuses.append(await handle.status())
        }
        return statuses
    }

    /// Update session settings.
    public func updateSettings(_ newSettings: SessionSettings) {
        self.settings = newSettings
    }

    /// Start DHT if enabled.
    public func startDHT() async throws {
        guard settings.dhtEnabled else { return }
        if dhtNode != nil {
            startDHTPeerDiscoveryLoop()
            return
        }
        let node = DHTNode(port: settings.dhtPort, group: group)
        try await node.start()
        self.dhtNode = node
        await discoverDHTPeersOnce()
        startDHTPeerDiscoveryLoop()
    }

    /// Pause all torrents.
    public func pauseAll() async {
        for handle in torrents.values {
            await handle.pause()
        }
    }

    /// Resume all torrents.
    public func resumeAll() async throws {
        for handle in torrents.values {
            try await handle.resume()
        }
    }

    /// Shutdown the session.
    public func shutdown() async throws {
        dhtPeerDiscoveryTask?.cancel()
        await pauseAll()
        alertContinuation.finish()
        try await group.shutdownGracefully()
    }

    private func startDHTPeerDiscoveryLoop() {
        guard dhtPeerDiscoveryTask == nil else { return }
        dhtPeerDiscoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.discoverDHTPeersOnce()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func discoverDHTPeersOnce() async {
        guard let dhtNode else { return }
        for handle in torrents.values {
            guard await handle.isRunning else { continue }
            await discoverPeers(for: handle, using: dhtNode)
        }
    }

    private func discoverPeers(for handle: TorrentHandle, using dhtNode: DHTNode) async {
        let traversal = DHTTraversal(dhtNode: dhtNode)
        guard let peers = try? await traversal.getPeers(infoHash: handle.infoHash),
              peers.isEmpty == false else {
            return
        }
        await handle.addDiscoveredPeers(peers)
    }
}
