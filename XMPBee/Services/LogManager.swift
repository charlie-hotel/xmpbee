import Foundation

/// Manages writing chat logs to disk
class LogManager {
    static let shared = LogManager()

    private let fileManager = FileManager.default
    private let logQueue = DispatchQueue(label: "com.xmpbee.logging", qos: .utility)

    private var logsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let xmpbeeDir = appSupport.appendingPathComponent("XMPBee")
        let logsDir = xmpbeeDir.appendingPathComponent("logs")

        // Create directory if it doesn't exist
        try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)

        return logsDir
    }

    /// Shared log formatters — only ever accessed from logQueue (serial), so thread-safe.
    private static let logDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone.current
        return fmt
    }()
    private static let logTimeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        fmt.timeZone = TimeZone.current
        return fmt
    }()

    private init() {}

    /// Sanitize a path component to prevent directory traversal and injection.
    /// Removes control characters, null bytes, backslashes, path separators,
    /// and path-traversal sequences.
    private func sanitizeName(_ name: String) -> String {
        var safe = name
        // Strip control characters (U+0000–U+001F) and DEL (U+007F)
        safe = safe.unicodeScalars
            .filter { $0.value >= 0x20 && $0.value != 0x7F }
            .map { String($0) }
            .joined()
        // Remove filesystem-unsafe characters
        safe = safe.replacingOccurrences(of: "/",  with: "_")
        safe = safe.replacingOccurrences(of: "\\", with: "_")
        // Neutralise path-traversal sequences
        safe = safe.replacingOccurrences(of: "..", with: "__")
        // Strip leading dots (hidden files on macOS)
        while safe.hasPrefix(".") { safe = "_" + safe.dropFirst() }
        // Enforce a reasonable max length
        if safe.count > 200 { safe = String(safe.prefix(200)) }
        return safe.isEmpty ? "_unknown" : safe
    }

    /// Log a message to disk
    func logMessage(server: String, room: String, timestamp: Date, sender: String, body: String, type: String) {
        logQueue.async { [weak self] in
            guard let self = self else { return }

            let dateString = LogManager.logDateFormatter.string(from: timestamp)
            let timeString = LogManager.logTimeFormatter.string(from: timestamp)

            // Sanitize server and room names for filesystem
            let safeServer = self.sanitizeName(server)
            let safeRoom   = self.sanitizeName(room)

            // Create server directory if needed
            let serverDir = self.logsDirectory.appendingPathComponent(safeServer)
            try? self.fileManager.createDirectory(at: serverDir, withIntermediateDirectories: true)

            // Create room directory if needed
            let roomDir = serverDir.appendingPathComponent(safeRoom)
            try? self.fileManager.createDirectory(at: roomDir, withIntermediateDirectories: true)

            // Log file path: logs/server/room/2026-02-17.txt
            let logFile = roomDir.appendingPathComponent("\(dateString).txt")

            // Format log entry
            let logEntry: String
            switch type {
            case "chat":
                logEntry = "[\(timeString)] <\(sender)> \(body)\n"
            case "action":
                logEntry = "[\(timeString)] * \(sender) \(body)\n"
            case "join":
                logEntry = "[\(timeString)] → \(sender) has joined\n"
            case "part":
                logEntry = "[\(timeString)] ← \(sender) has left\(body.isEmpty ? "" : " (\(body))")\n"
            case "quit":
                logEntry = "[\(timeString)] ⇐ \(sender) has quit\(body.isEmpty ? "" : " (\(body))")\n"
            case "topic":
                logEntry = "[\(timeString)] ✦ \(sender) changed the topic to: \(body)\n"
            case "system":
                logEntry = "[\(timeString)] • \(body)\n"
            default:
                logEntry = "[\(timeString)] [\(type)] \(sender): \(body)\n"
            }

            // Check for duplicates before writing using timestamp+sender+body as key
            // This handles multi-line messages correctly
            if self.fileManager.fileExists(atPath: logFile.path) {
                if let content = try? String(contentsOf: logFile, encoding: .utf8) {
                    // For chat messages, create dedup key from the message components
                    if type == "chat" {
                        let dedupKey = "[\(timeString)] <\(sender)> \(body)"
                        if content.contains(dedupKey) {
                            return
                        }
                    } else if type == "action" {
                        let dedupKey = "[\(timeString)] * \(sender) \(body)"
                        if content.contains(dedupKey) {
                            return
                        }
                    } else {
                        // For other types, just check if the exact entry exists
                        if content.contains(logEntry.trimmingCharacters(in: .newlines)) {
                            return
                        }
                    }
                }
            }

            // Append to log file
            if let data = logEntry.data(using: .utf8) {
                if self.fileManager.fileExists(atPath: logFile.path) {
                    // Append to existing file
                    if let fileHandle = try? FileHandle(forWritingTo: logFile) {
                        fileHandle.seekToEndOfFile()
                        fileHandle.write(data)
                        try? fileHandle.close()
                    }
                } else {
                    // Create new file
                    try? data.write(to: logFile)
                }
            }
        }
    }

    /// Get list of all servers that have logs
    func getLoggedServers() -> [String] {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: logsDirectory.path) else {
            return []
        }
        return contents.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Get list of all rooms for a server that have logs
    func getLoggedRooms(for server: String) -> [String] {
        let serverDir = logsDirectory.appendingPathComponent(sanitizeName(server))
        guard let contents = try? fileManager.contentsOfDirectory(atPath: serverDir.path) else {
            return []
        }
        return contents.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Get list of all log dates for a server/room
    func getLogDates(server: String, room: String) -> [String] {
        let roomDir = logsDirectory.appendingPathComponent(sanitizeName(server)).appendingPathComponent(sanitizeName(room))
        guard let contents = try? fileManager.contentsOfDirectory(atPath: roomDir.path) else {
            return []
        }
        return contents
            .filter { $0.hasSuffix(".txt") }
            .map { $0.replacingOccurrences(of: ".txt", with: "") }
            .sorted(by: >) // Newest first
    }

    /// Read log content for a specific date
    func readLog(server: String, room: String, date: String) -> String {
        let logFile = logsDirectory
            .appendingPathComponent(sanitizeName(server))
            .appendingPathComponent(sanitizeName(room))
            .appendingPathComponent("\(sanitizeName(date)).txt")

        guard let content = try? String(contentsOf: logFile, encoding: .utf8) else {
            return "No log found for \(date)"
        }

        return content
    }

    /// Parse a log line back into a ChatMessage
    /// Returns nil if the line can't be parsed or is a system/join/part message
    private func parseLogLine(_ line: String, for date: String, using formatter: DateFormatter) -> ChatMessage? {
        // Skip empty lines
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // Match timestamp pattern [HH:mm:ss]
        guard line.hasPrefix("["), let firstClose = line.firstIndex(of: "]") else { return nil }
        let timeString = String(line[line.index(after: line.startIndex)..<firstClose])
        let rest = String(line[line.index(after: firstClose)...]).trimmingCharacters(in: .whitespaces)

        guard let timestamp = formatter.date(from: "\(date) \(timeString)") else { return nil }

        // Parse different message types
        if rest.hasPrefix("<") {
            // Chat message: <sender> body
            guard let closeAngle = rest.firstIndex(of: ">") else { return nil }
            let sender = String(rest[rest.index(after: rest.startIndex)..<closeAngle])
            let body = String(rest[rest.index(after: closeAngle)...]).trimmingCharacters(in: .whitespaces)
            return ChatMessage(
                timestamp: timestamp,
                sender: sender,
                body: body,
                type: .chat,
                senderColor: ChatMessage.colorForNick(sender)
            )
        } else if rest.hasPrefix("*") {
            // Action message: * sender body
            let actionRest = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            guard let spaceIdx = actionRest.firstIndex(of: " ") else { return nil }
            let sender = String(actionRest[actionRest.startIndex..<spaceIdx])
            let body = String(actionRest[actionRest.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespaces)
            return ChatMessage(
                timestamp: timestamp,
                sender: sender,
                body: body,
                type: .action,
                senderColor: ChatMessage.colorForNick(sender)
            )
        }

        // Skip system messages, join/part, topic changes - we don't want those in scrollback
        return nil
    }

    /// Load recent message history for a room (last N days).
    /// Returns messages sorted chronologically (oldest first).
    /// Safe to call from any thread — does NOT dispatch internally.
    func loadRecentHistory(server: String, room: String, days: Int = 7, limit: Int = 100) -> [ChatMessage] {
        let startTime = CFAbsoluteTimeGetCurrent()
        var messages: [ChatMessage] = []

        let safeServer = sanitizeName(server)
        let safeRoom   = sanitizeName(room)

        let dates = getLogDates(server: safeServer, room: safeRoom)

        // Create formatter once for the whole load — DateFormatter is expensive to allocate
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone.current

        // Get the most recent 'days' worth of logs
        let relevantDates = Array(dates.prefix(days))

        for date in relevantDates.reversed() { // Process oldest to newest
            let content = readLog(server: safeServer, room: safeRoom, date: date)
            let lines = content.components(separatedBy: .newlines)

            var currentMessage: ChatMessage? = nil
            var accumulatedBody: [String] = []

            for line in lines {
                if line.hasPrefix("[") {
                    if var msg = currentMessage {
                        if !accumulatedBody.isEmpty {
                            msg = ChatMessage(
                                timestamp: msg.timestamp,
                                sender: msg.sender,
                                body: accumulatedBody.joined(separator: "\n"),
                                type: msg.type,
                                senderColor: msg.senderColor
                            )
                        }
                        messages.append(msg)
                    }
                    currentMessage = parseLogLine(line, for: date, using: formatter)
                    accumulatedBody = currentMessage.map { [$0.body] } ?? []
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty && currentMessage != nil {
                    accumulatedBody.append(line)
                }
            }

            // Flush the last message in the file
            if var msg = currentMessage {
                if !accumulatedBody.isEmpty {
                    msg = ChatMessage(
                        timestamp: msg.timestamp,
                        sender: msg.sender,
                        body: accumulatedBody.joined(separator: "\n"),
                        type: msg.type,
                        senderColor: msg.senderColor
                    )
                }
                messages.append(msg)
            }
        }

        if messages.count > limit {
            messages = Array(messages.suffix(limit))
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        #if DEBUG
        print("[PERF] loadRecentHistory for \(room): \(messages.count) messages in \(String(format: "%.3f", elapsed))s")
        #endif
        return messages
    }

    /// Clear all logs
    func clearAllLogs() {
        try? fileManager.removeItem(at: logsDirectory)
        // Recreate the directory
        try? fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }

    /// Clear logs for a specific server
    func clearServerLogs(server: String) {
        let serverDir = logsDirectory.appendingPathComponent(sanitizeName(server))
        try? fileManager.removeItem(at: serverDir)
    }

    /// Clear logs for a specific room
    func clearRoomLogs(server: String, room: String) {
        let roomDir = logsDirectory.appendingPathComponent(sanitizeName(server)).appendingPathComponent(sanitizeName(room))
        try? fileManager.removeItem(at: roomDir)
    }
}
