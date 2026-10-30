import ConnectionCore
import Foundation

/// Writes scrcpy control messages to the control link, one at a time, in the order `send` is
/// called. After a failed write it drops everything (the link has ended; the session sees that
/// on its read side).
public actor ControlWriter {
    private let pipe: any BulkPipe
    private var failed = false

    public init(pipe: any BulkPipe) {
        self.pipe = pipe
    }

    public func send(_ bytes: Data) async {
        guard !failed, !bytes.isEmpty else { return }
        do {
            try await pipe.send(bytes)
        } catch {
            failed = true
        }
    }
}
