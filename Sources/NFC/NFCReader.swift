import CoreNFC
import Combine
import Observation
import os

fileprivate let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "NFCReader")

public enum NFCReaderError: LocalizedError {
    case noSession
    case noRecords
    case noURI
    case writingNotSupported
    case writingNotAllowed
    case writingUnknownStatus
    case writingTooSmall((needed: Int, capacity: Int))
    
    public var errorDescription: String? {
        switch self {
        case .writingNotSupported:
            "This tag does not support writing."
        case .writingNotAllowed:
            "This tag has been locked to read-only."
        case .writingTooSmall((let needed, let capacity)):
            "\(needed) bytes required, but tag only holds \(capacity)."
        default:
            nil
        }
    }
}

extension NFCNDEFStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notSupported:
            "notSupported"
        case .readWrite:
            "readWrite"
        case .readOnly:
            "readOnly"
        @unknown default:
            "unknown"
        }
    }
}

@Observable
public class NFCReader: NSObject, NFCNDEFReaderSessionDelegate, Identifiable {
    public let id: UUID
    public private(set) var state: State
    public let tagPublisher = PassthroughSubject<NFCNDEFTag, Never>()
    
    public static var isReadingAvailable: Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        NFCReaderSession.readingAvailable
        #endif
    }
    
    public enum State {
        case notAvailable
        case setup
        case starting(NFCNDEFReaderSession)
        case active(NFCNDEFReaderSession)
        case invalid(Error)
    }
    
    public override init() {
        self.id = UUID()
        if Self.isReadingAvailable {
            self.state = .setup
        } else {
            self.state = .notAvailable
        }
        super.init()
        logger.debug("🪪 \(self.id) init")
    }
    
    // Generally speaking this object should be treated as a singleton.
    // So if you see it being destroyed and recreated in your SwiftUI
    // app, it's probably not going to have the behavior you expect.
    // https://github.com/BlockchainCommons/GordianSeedTool-iOS/issues/205
    deinit {
        logger.debug("🪪 \(self.id) deinit")
    }
    
    private var continuation: CheckedContinuation<Void, Error>?
    
    public var canBeginSession: Bool {
        switch state {
        case .notAvailable, .starting, .active:
            return false
        case .setup, .invalid:
            return true
        }
    }
    
    @MainActor
    public func beginSession(alertMessage: String? = nil) async throws {
        logger.debug("🪪 \(self.id) beginSession")
        guard canBeginSession else {
            return
        }

        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let session = NFCNDEFReaderSession(delegate: self, queue: DispatchQueue.main, invalidateAfterFirstRead: true)
            if let alertMessage = alertMessage {
                session.alertMessage = alertMessage
            }
            self.continuation = continuation
            self.state = .starting(session)
            logger.debug("🪪 \(self.id) session.begin()")
            session.begin()
        }
    }
    
    @MainActor
    public func invalidate(errorMessage: String? = nil) {
        logger.debug("🪪 \(self.id) session.invalidate(\(String(describing: errorMessage)))")
        guard case let .active(session) = state else {
            return
        }
        if let errorMessage = errorMessage {
            session.invalidate(errorMessage: errorMessage)
        } else {
            session.invalidate()
        }
    }
    
    @MainActor
    public func readTag(_ tag: NFCNDEFTag) async throws -> NFCNDEFMessage {
        logger.debug("🪪 \(self.id) readTag(\(tag.description))")
        guard case .active = state else {
            throw NFCReaderError.noSession
        }
        try await connect(to: tag)
        return try await tag.readNDEF()
    }
    
    @MainActor
    public func readURI(_ tag: NFCNDEFTag) async throws -> URL {
        logger.debug("🪪 \(self.id) readURI(\(tag.description))")
        let message = try await readTag(tag)
        guard let record = message.records.first else {
            throw NFCReaderError.noRecords
        }
        guard let uri = record.wellKnownTypeURIPayload() else {
            throw NFCReaderError.noURI
        }
        return uri
    }
    
    @MainActor
    public func writeTag(_ tag: NFCNDEFTag, message: NFCNDEFMessage) async throws {
        logger.debug("🪪 \(self.id) writeTag(\(tag.description), \(message))")
        let (status, capacity) = try await queryStatus(tag)
        
        switch status {
        case .notSupported:
            throw NFCReaderError.writingNotSupported
        case .readOnly:
            throw NFCReaderError.writingNotAllowed
        case .readWrite:
            break
        @unknown default:
            throw NFCReaderError.writingUnknownStatus
        }
        
        if capacity < message.length {
            throw NFCReaderError.writingTooSmall((message.length, capacity))
        }

        try await connect(to: tag)

        try await tag.writeNDEF(message)
    }
    
    @MainActor
    public func writeURI(_ tag: NFCNDEFTag, uri: URL) async throws {
        logger.debug("🪪 \(self.id) writeURI(\(tag.description), \(uri, privacy: .private))")
        let payload = NFCNDEFPayload.wellKnownTypeURIPayload(url: uri)!
        let message = NFCNDEFMessage(records: [payload])
        try await writeTag(tag, message: message)
    }
    
    @MainActor
    public func queryStatus(_ tag: NFCNDEFTag) async throws -> (NFCNDEFStatus, Int) {
        try await tag.queryNDEFStatus()
    }
    
    public func readerSessionDidBecomeActive(_ session: NFCNDEFReaderSession) {
        logger.debug("🪪 \(self.id) readerSessionDidBecomeActive(\(session))")
        self.state = .active(session)
        self.continuation!.resume(with: .success(()))
        self.continuation = nil
    }
    
    public func readerSession(_ session: NFCNDEFReaderSession, didDetect tags: [NFCNDEFTag]) {
        logger.debug("🪪 \(self.id) readerSession(\(session), didDetect: \(tags))")
        if tags.count > 1 {
            // Restart polling in 500ms
            let retryInterval = DispatchTimeInterval.milliseconds(500)
            session.alertMessage = "More than 1 tag is detected, please remove all tags and try again."
            DispatchQueue.global().asyncAfter(deadline: .now() + retryInterval, execute: {
                session.restartPolling()
            })
            return
        }

        sendTag(tags.first!)
    }
    
    private func sendTag(_ tag: NFCNDEFTag) {
        logger.debug("🪪 \(self.id) sendTag(\(tag.description))")
        tagPublisher.send(tag)
    }
    
    public func connect(to tag: NFCNDEFTag) async throws {
        logger.debug("🪪 \(self.id) connect(\(tag.description))")
        guard case .active(let session) = state else {
            throw NFCReaderError.noSession
        }
        try await session.connect(to: tag)
    }
    
    public func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        logger.debug("🪪 \(self.id) readerSession(\(session), didDetectNDEFs:\(messages))")
        // Required but never called because readerSession:didDetect:() is provided
    }

    public func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        logger.debug("🪪 \(self.id) readerSession(\(session), didInvalidateWithError:\(error))")
        state = .invalid(error)
        if let continuation = continuation {
            continuation.resume(with: .failure(error))
            self.continuation = nil
        }
    }
}
