import Foundation

/// HTTP tracker client (BEP-3).
public struct HTTPTracker: Sendable {
    public let announceURL: String

    public init(announceURL: String) {
        self.announceURL = announceURL
    }

    /// Announce to the tracker.
    public func announce(params: AnnounceParams) async throws -> AnnounceResponse {
        var components = URLComponents(string: announceURL)
        guard components != nil else {
            throw TrackerError.invalidURL
        }

        var queryItems = [
            "info_hash=\(Self.percentEncoded(params.infoHash.bytes))",
            "peer_id=\(Self.percentEncoded(params.peerID))",
            "port=\(params.port)",
            "uploaded=\(params.uploaded)",
            "downloaded=\(params.downloaded)",
            "left=\(params.left)",
            "compact=1",
            "numwant=\(params.numWant)",
        ]
        if let event = params.event {
            queryItems.append("event=\(Self.percentEncoded(Data(event.utf8)))")
        }

        if let existingQuery = components?.percentEncodedQuery, existingQuery.isEmpty == false {
            queryItems.insert(existingQuery, at: 0)
        }
        components?.percentEncodedQuery = queryItems.joined(separator: "&")

        guard let url = components?.url else {
            throw TrackerError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        return try parseAnnounceResponse(data)
    }

    private static func percentEncoded(_ data: Data) -> String {
        data.map { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."),
                 UInt8(ascii: "-"),
                 UInt8(ascii: "_"),
                 UInt8(ascii: "~"):
                String(UnicodeScalar(byte))
            default:
                String(format: "%%%02X", byte)
            }
        }.joined()
    }

    private func parseAnnounceResponse(_ data: Data) throws -> AnnounceResponse {
        let decoder = BencodeDecoder()
        let value = try decoder.decode(data)

        if let failure = value["failure reason"]?.utf8String {
            throw TrackerError.failure(failure)
        }

        let interval = value["interval"]?.integerValue.map(Int.init) ?? 1800
        let seeders = value["complete"]?.integerValue.map(Int.init) ?? 0
        let leechers = value["incomplete"]?.integerValue.map(Int.init) ?? 0

        var peers: [(String, UInt16)] = []

        if let peersData = value["peers"]?.stringValue {
            // Compact format: 6 bytes per peer (4 IP + 2 port)
            var offset = 0
            while offset + 6 <= peersData.count {
                let ip = "\(peersData[offset]).\(peersData[offset+1]).\(peersData[offset+2]).\(peersData[offset+3])"
                let port = UInt16(peersData[offset+4]) << 8 | UInt16(peersData[offset+5])
                peers.append((ip, port))
                offset += 6
            }
        } else if let peersList = value["peers"]?.listValue {
            // Dictionary format
            for peerValue in peersList {
                if let ip = peerValue["ip"]?.utf8String,
                   let port = peerValue["port"]?.integerValue {
                    peers.append((ip, UInt16(port)))
                }
            }
        }

        return AnnounceResponse(
            interval: interval, seeders: seeders, leechers: leechers, peers: peers
        )
    }
}

public struct AnnounceParams: Sendable {
    public let infoHash: InfoHash
    public let peerID: Data
    public let port: UInt16
    public let uploaded: Int64
    public let downloaded: Int64
    public let left: Int64
    public let numWant: Int
    public let event: String?  // "started", "stopped", "completed"

    public init(infoHash: InfoHash, peerID: Data, port: UInt16,
                uploaded: Int64 = 0, downloaded: Int64 = 0, left: Int64,
                numWant: Int = 50, event: String? = nil) {
        self.infoHash = infoHash
        self.peerID = peerID
        self.port = port
        self.uploaded = uploaded
        self.downloaded = downloaded
        self.left = left
        self.numWant = numWant
        self.event = event
    }
}

public struct AnnounceResponse: Sendable {
    public let interval: Int
    public let seeders: Int
    public let leechers: Int
    public let peers: [(String, UInt16)]
}

public enum TrackerError: Error, Equatable {
    case invalidURL
    case failure(String)
    case invalidResponse
    case connectionFailed
}
