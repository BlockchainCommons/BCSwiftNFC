import CoreNFC
import Combine

public enum NFCReaderError: Error {
    case noSession
    case noRecords
    case noURI
}

public class NFCReader: NSObject, ObservableObject, NFCNDEFReaderSessionDelegate {
    @Published public var state: State
    public let tagPublisher = PassthroughSubject<NFCNDEFTag, Never>()
    
    public static var isReadingAvailable: Bool {
        NFCReaderSession.readingAvailable
    }
    
    public enum State {
        case notAvailable
        case setup
        case starting(NFCNDEFReaderSession)
        case active(NFCNDEFReaderSession)
        case invalid(Error)
    }
    
    public override init() {
        if NFCReaderSession.readingAvailable {
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
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NFCNDEFMessage, Error>) in
            tag.readNDEF { message, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let message = message {
                    continuation.resume(returning: message)
                } else {
                    fatalError()
                }
            }
        }
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
