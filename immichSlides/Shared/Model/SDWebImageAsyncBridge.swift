import Foundation
import SDWebImage
import Combine
import OSLog

// SDWebImage callback bridge: the continuation resumes only once; cancelling the Task also cancels the operation.

nonisolated final class SDWebImageAsyncBridge<Output>: @unchecked Sendable {
    private let lock = NSLock()
    private let fallbackValue: Output
    private var continuation: CheckedContinuation<Output, Never>?
    private var operation: SDWebImageOperation?
    private var didResume = false
    private var shouldCancelOperation = false

    init(fallbackValue: Output) {
        self.fallbackValue = fallbackValue
    }

    func setContinuation(_ continuation: CheckedContinuation<Output, Never>) {
        let shouldResumeImmediately: Bool

        lock.lock()
        if didResume {
            shouldResumeImmediately = true
        } else {
            self.continuation = continuation
            shouldResumeImmediately = false
        }
        lock.unlock()

        if shouldResumeImmediately {
            continuation.resume(returning: fallbackValue)
        }
    }

    func setOperation(_ operation: SDWebImageOperation) {
        let shouldCancelImmediately: Bool

        lock.lock()
        if didResume || shouldCancelOperation {
            shouldCancelImmediately = true
        } else {
            self.operation = operation
            shouldCancelImmediately = false
        }
        lock.unlock()

        if shouldCancelImmediately {
            operation.cancel()
        }
    }

    func resume(returning value: Output, cancelOperation: Bool = false) {
        let continuationToResume: CheckedContinuation<Output, Never>?
        let operationToCancel: SDWebImageOperation?

        lock.lock()
        if didResume {
            if cancelOperation {
                shouldCancelOperation = true
                operationToCancel = operation
                operation = nil
            } else {
                operationToCancel = nil
            }
            continuationToResume = nil
            lock.unlock()
        } else {
            didResume = true
            shouldCancelOperation = cancelOperation
            continuationToResume = continuation
            continuation = nil
            operationToCancel = cancelOperation ? operation : nil
            operation = nil
            lock.unlock()
        }

        if cancelOperation {
            operationToCancel?.cancel()
        }
        continuationToResume?.resume(returning: value)
    }

    func cancelAndResume() {
        resume(returning: fallbackValue, cancelOperation: true)
    }
}
