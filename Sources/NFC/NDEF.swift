import CoreNFC

public class NDEF {
    let session: NFCNDEFReaderSession
    let delegate: Delegate
    
    public static var isReadingAvailable: Bool {
        NFCReaderSession.readingAvailable
    }
    
    @MainActor
    public init?(alertMessage: String) {
        guard NFCReaderSession.readingAvailable else {
            return nil
        }
        self.delegate = Delegate()
        self.session = NFCNDEFReaderSession(delegate: self.delegate, queue: nil, invalidateAfterFirstRead: false)
        self.session.alertMessage = alertMessage
    }
    
    @MainActor
    public func beginSession() async throws {
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.reset()
            delegate.didBecomeActive = {
                continuation.resume(with: .success(()))
            }
            delegate.didInvalidate = { error in
                continuation.resume(with: .failure(error))
            }
            session.begin()
        }
    }

    class Delegate: NSObject, NFCNDEFReaderSessionDelegate {
        var didBecomeActive: (() -> Void)?
        var didDetectNDEFs: (([NFCNDEFMessage]) -> Void)?
        var didInvalidate: ((Error) -> Void)?
        
        func reset() {
            didBecomeActive = nil
            didDetectNDEFs = nil
            didInvalidate = nil
        }
        
        func readerSessionDidBecomeActive(_ session: NFCNDEFReaderSession) {
            didBecomeActive!()
        }
        
        func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
            didDetectNDEFs!(messages)
        }
        
        func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
            didInvalidate!(error)
        }
    }
}
