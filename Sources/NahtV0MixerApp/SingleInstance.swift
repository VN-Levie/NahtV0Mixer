import AppKit
import Darwin
import Foundation

/// Ownership belongs to the open file description. Leaving this file on disk is
/// intentional: a stale file is harmless, while deleting it can split ownership.
final class InstanceLease {
    private let file: Int32
    private init(file: Int32) { self.file = file }
    deinit { close(file) }

    static func take(_ url: URL) throws -> InstanceLease? {
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd != -1 else { throw systemError() }
        var metadata = stat()
        if fstat(fd, &metadata) != 0 {
            let failure = systemError()
            close(fd)
            throw failure
        }
        guard metadata.st_uid == geteuid(), (metadata.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw POSIXError(.EACCES)
        }
        let result = flock(fd, LOCK_NB | LOCK_EX)
        if result == 0 { return InstanceLease(file: fd) }
        let code = errno
        close(fd)
        if code == EWOULDBLOCK || code == EAGAIN { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private static func systemError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

@MainActor
final class SingleInstance: NSObject {
    static let bundleIdentifier = "vn.levie.NahtV0Mixer"
    // Keep the existing lease and notification channel across the bundle-ID
    // migration so an old running build and a new build cannot both own audio.
    private static let leaseIdentifier = "com.levie.NahtV0Mixer"
    private let location: URL
    private let channel = "com.levie.NahtV0Mixer.user.\(getuid())"
    private let requests = Notification.Name("com.levie.NahtV0Mixer.present")
    private let replies = Notification.Name("com.levie.NahtV0Mixer.presented")
    private var lease: InstanceLease?
    private var observing = false
    private var queuedPresentation = false
    private var pendingID: String?
    private var pendingReply: ((Bool) -> Void)?
    private var acknowledgedIDs: Set<String> = []
    var isOwner: Bool { lease != nil }
    var onPresent: (() -> Void)? {
        didSet {
            if queuedPresentation, let onPresent {
                queuedPresentation = false
                onPresent()
            }
        }
    }

    init(lockURL: URL? = nil) {
        location = lockURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.leaseIdentifier, isDirectory: true)
            .appendingPathComponent("running.lock")
        super.init()
    }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    func claim() throws -> Bool {
        if isOwner { return true }
        if !observing {
            let center = DistributedNotificationCenter.default()
            center.addObserver(self, selector: #selector(receivePresentation(_:)), name: requests,
                               object: channel, suspensionBehavior: .deliverImmediately)
            center.addObserver(self, selector: #selector(receiveReply(_:)), name: replies,
                               object: channel, suspensionBehavior: .deliverImmediately)
            observing = true
        }
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        lease = try InstanceLease.take(location)
        return isOwner
    }

    func presentOwner(completion: @escaping (Bool) -> Void) {
        guard !isOwner else { onPresent?(); completion(true); return }
        let requestID = UUID().uuidString
        pendingReply?(false)
        pendingID = requestID
        pendingReply = completion
        sendPresentation(requestID, remaining: 15)
    }

    private func sendPresentation(_ id: String, remaining: Int) {
        guard pendingID == id else { return }
        guard remaining > 0 else { finishRequest(accepted: false); return }
        DistributedNotificationCenter.default().postNotificationName(requests, object: channel,
            userInfo: ["request": id], deliverImmediately: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.sendPresentation(id, remaining: remaining - 1)
        }
    }

    @objc private func receivePresentation(_ notification: Notification) {
        guard isOwner, let id = notification.userInfo?["request"] as? String, UUID(uuidString: id) != nil else { return }
        if acknowledgedIDs.insert(id).inserted {
            if let onPresent { onPresent() }
            else { queuedPresentation = true }
            // Requests contain no user content. Bound retained identifiers even if
            // another same-user process repeatedly requests the panel.
            if acknowledgedIDs.count > 32 { acknowledgedIDs = [id] }
        }
        DistributedNotificationCenter.default().postNotificationName(replies, object: channel,
            userInfo: ["request": id], deliverImmediately: true)
    }

    @objc private func receiveReply(_ notification: Notification) {
        guard !isOwner, let id = notification.userInfo?["request"] as? String, id == pendingID else { return }
        finishRequest(accepted: true)
    }

    private func finishRequest(accepted: Bool) {
        let callback = pendingReply
        pendingReply = nil
        pendingID = nil
        callback?(accepted)
    }

    func release() {
        DistributedNotificationCenter.default().removeObserver(self)
        observing = false
        lease = nil
        onPresent = nil
        queuedPresentation = false
        acknowledgedIDs.removeAll()
        finishRequest(accepted: false)
    }
}
