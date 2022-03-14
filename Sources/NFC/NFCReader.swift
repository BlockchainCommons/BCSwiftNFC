import CoreNFC
import Combine

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
            return "This tag does not support writing."
        case .writingNotAllowed:
            return "This tag has been locked to read-only."
        case .writingTooSmall((let needed, let capacity)):
            return "\(needed) bytes required, but tag only holds \(capacity)."
        default:
            return nil
        }
    }
}

extension NFCNDEFStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notSupported:
            return "notSupported"
        case .readWrite:
            return "readWrite"
        case .readOnly:
            return "readOnly"
        @unknown default:
            return "unknown"
        }
    }
}

public class NFCReader: NSObject, ObservableObject, NFCNDEFReaderSessionDelegate {
    @Published public var state: State
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
        if Self.isReadingAvailable {
            self.state = .setup
        } else {
            self.state = .notAvailable
        }
        super.init()
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
            session.begin()
        }
    }
    
    @MainActor
    public func invalidate(errorMessage: String? = nil) {
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
        guard case .active = state else {
            throw NFCReaderError.noSession
        }
        return try await tag.readNDEF()
    }
    
    @MainActor
    public func readURI(_ tag: NFCNDEFTag) async throws -> URL {
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

        try await tag.writeNDEF(message)
    }
    
    @MainActor
    public func writeURI(_ tag: NFCNDEFTag, uri: URL) async throws {
        let payload = NFCNDEFPayload.wellKnownTypeURIPayload(url: uri)!
        let message = NFCNDEFMessage(records: [payload])
        try await writeTag(tag, message: message)
    }
    
    @MainActor
    public func queryStatus(_ tag: NFCNDEFTag) async throws -> (NFCNDEFStatus, Int) {
        try await tag.queryNDEFStatus()
    }
    
    public func readerSessionDidBecomeActive(_ session: NFCNDEFReaderSession) {
        self.state = .active(session)
        self.continuation!.resume(with: .success(()))
        self.continuation = nil
    }
    
    public func readerSession(_ session: NFCNDEFReaderSession, didDetect tags: [NFCNDEFTag]) {
        guard let tag = tags.first else {
            return
        }
        tagPublisher.send(tag)
    }
    
    public func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        // Required but never called because readerSession:didDetect:() is provided
    }

    public func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        state = .invalid(error)
        if let continuation = continuation {
            continuation.resume(with: .failure(error))
            self.continuation = nil
        }
    }
}
