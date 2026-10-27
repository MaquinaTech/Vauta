// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreServices
import Foundation

/// Watches one local source with FSEvents and says when something under it changed. It only reports "something changed":
/// the indexer scans the source (events are not trusted to be complete, and a periodic scan is the safety net). Events
/// inside the source's security scope only, which is all the stream is created for.
final class SourceWatcher: @unchecked Sendable {
    /// What the stream's callback talks to. The stream retains it (see the context below), so an event that is already queued when the
    /// watcher is stopped or released still finds a live object, which no longer calls the handler.
    private final class Target: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable () -> Void)?
        init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }

        func fire() {
            let current = lock.withLock { handler }
            current?()
        }

        func cancel() { lock.withLock { handler = nil } }
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "vauta.documents.watcher", qos: .background)
    private let target: Target

    /// `latency`: events are coalesced for this long.
    init?(url: URL, latency: TimeInterval = 5, handler: @escaping @Sendable () -> Void) {
        target = Target(handler)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(target).toOpaque(),
                                           retain: { info in
                                               guard let info else { return nil }
                                               _ = Unmanaged<Target>.fromOpaque(info).retain()
                                               return info
                                           },
                                           release: { info in
                                               guard let info else { return }
                                               Unmanaged<Target>.fromOpaque(info).release()
                                           }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Target>.fromOpaque(info).takeUnretainedValue().fire()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        target.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
