import Foundation

public final class WidgetSharedStore: @unchecked Sendable {
    public static let kind = "NahtV0MixerWidget"

    private static let maxRecordBytes = 128 * 1024
    private static let maxQueueRecords = 128
    private static let maxPendingRecords = 32
    private static let retention: TimeInterval = 24 * 60 * 60

    public let directory: URL
    private let fileManager: FileManager

    public static func configured(bundle: Bundle = .main) throws -> WidgetSharedStore {
        guard let group = bundle.object(forInfoDictionaryKey: "NahtV0MixerAppGroup") as? String,
              !group.isEmpty, !group.contains("$"), !group.hasPrefix("."),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { throw WidgetStoreError.appGroupUnavailable }
        return try WidgetSharedStore(directory: container.appendingPathComponent("Library/Application Support/NahtV0Mixer", isDirectory: true))
    }

    public init(directory: URL) throws {
        self.fileManager = .default
        self.directory = directory.standardizedFileURL
        try Self.ensureDirectory(self.directory, fileManager: fileManager)
        try Self.ensureDirectory(self.directory.appendingPathComponent("commands", isDirectory: true), fileManager: fileManager)
        try Self.ensureDirectory(self.directory.appendingPathComponent("replies", isDirectory: true), fileManager: fileManager)
    }

    public func readSnapshot() -> WidgetSnapshot? {
        guard let snapshot: WidgetSnapshot = read(WidgetSnapshot.self, from: directory.appendingPathComponent("snapshot.json")),
              snapshot.schemaVersion == 1 else { return nil }
        return snapshot
    }

    public func writeSnapshot(_ snapshot: WidgetSnapshot) throws {
        try write(snapshot, to: directory.appendingPathComponent("snapshot.json"))
    }

    public func submit(_ command: WidgetCommand) throws {
        try write(command, to: commandURL(command.id))
    }

    public func pendingCommands() -> [WidgetCommand] {
        let urls = ownedRecordURLs(in: directory.appendingPathComponent("commands", isDirectory: true))
        var commands: [WidgetCommand] = []
        for url in urls {
            guard let command: WidgetCommand = read(WidgetCommand.self, from: url),
                  command.id.uuidString.caseInsensitiveCompare(url.deletingPathExtension().lastPathComponent) == .orderedSame else {
                try? removeOwnedRecord(url)
                continue
            }
            commands.append(command)
        }
        return commands.sorted { lhs, rhs in
            lhs.issuedAt == rhs.issuedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.issuedAt < rhs.issuedAt
        }.prefix(Self.maxPendingRecords).map { $0 }
    }

    public func removeCommand(id: UUID) throws {
        try removeOwnedRecord(commandURL(id), throwing: true)
    }

    public func writeReply(_ reply: WidgetReply) throws {
        try write(reply, to: replyURL(reply.id))
    }

    public func readReply(id: UUID) -> WidgetReply? {
        guard let reply: WidgetReply = read(WidgetReply.self, from: replyURL(id)), reply.id == id else { return nil }
        return reply
    }

    public func removeReply(id: UUID) throws {
        try removeOwnedRecord(replyURL(id), throwing: true)
    }

    public func prune(at now: Date = Date()) {
        pruneDirectory(directory.appendingPathComponent("commands", isDirectory: true), now: now)
        pruneDirectory(directory.appendingPathComponent("replies", isDirectory: true), now: now)
    }

    private func commandURL(_ id: UUID) -> URL { directory.appendingPathComponent("commands").appendingPathComponent(Self.filename(id)) }
    private func replyURL(_ id: UUID) -> URL { directory.appendingPathComponent("replies").appendingPathComponent(Self.filename(id)) }
    private static func filename(_ id: UUID) -> String { "\(id.uuidString).json" }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= Self.maxRecordBytes else { throw WidgetStoreError.recordTooLarge }
        try Self.ensureDirectory(url.deletingLastPathComponent(), fileManager: fileManager)
        guard !Self.isSymlink(url, fileManager: fileManager) else { throw WidgetStoreError.symlinkRejected }
        try data.write(to: url, options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard Self.isRegularOwnedFile(url, fileManager: fileManager),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= Self.maxRecordBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= Self.maxRecordBytes
        else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func ownedRecordURLs(in directory: URL) -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap { name in
            guard Self.isUUIDJSONFilename(name) else { return nil }
            return directory.appendingPathComponent(name)
        }
    }

    private func pruneDirectory(_ directory: URL, now: Date) {
        let urls = ownedRecordURLs(in: directory)
        var records: [(URL, Date)] = []
        for url in urls {
            guard !Self.isSymlink(url, fileManager: fileManager) else { continue }
            guard let date = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else {
                try? removeOwnedRecord(url)
                continue
            }
            if now.timeIntervalSince(date) > Self.retention { try? removeOwnedRecord(url) }
            else if read(WidgetCommand.self, from: url) != nil || read(WidgetReply.self, from: url) != nil { records.append((url, date)) }
            else { try? removeOwnedRecord(url) }
        }
        if records.count > Self.maxQueueRecords {
            for (url, _) in records.sorted(by: { $0.1 < $1.1 }).prefix(records.count - Self.maxQueueRecords) { try? removeOwnedRecord(url) }
        }
    }

    private func removeOwnedRecord(_ url: URL, throwing: Bool = false) throws {
        guard Self.isUUIDJSONFilename(url.lastPathComponent), !Self.isSymlink(url, fileManager: fileManager) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile where !throwing {
        } catch {
            if throwing { throw error }
        }
    }

    private static func ensureDirectory(_ url: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: url.path) {
            guard !isSymlink(url, fileManager: fileManager), isDirectory(url, fileManager: fileManager) else { throw WidgetStoreError.invalidDirectory }
        } else { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) }
    }

    private static func isRegularOwnedFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path), !isSymlink(url, fileManager: fileManager) else { return false }
        return ((try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType) == .typeRegular
    }
    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool { ((try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType) == .typeDirectory }
    private static func isSymlink(_ url: URL, fileManager: FileManager) -> Bool {
        guard let type = (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType else { return false }
        return type == .typeSymbolicLink
    }
    private static func isUUIDJSONFilename(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        return UUID(uuidString: String(name.dropLast(5))) != nil
    }
}

public enum WidgetStoreError: Error, Equatable, Sendable {
    case appGroupUnavailable
    case invalidDirectory
    case recordTooLarge
    case symlinkRejected
}
