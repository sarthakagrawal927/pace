//
//  PaceMCPClient.swift
//  leanring-buddy
//
//  Minimal stdio MCP bridge. Pace stays the local approval/UI shell while
//  third-party servers own broad app integrations.
//

import Foundation

enum PaceMCPClientError: Error, CustomStringConvertible {
    case serverNotConfigured(String)
    case invalidCommand(String)
    case launchFailed(String)
    case requestTimedOut(String)
    case invalidResponse(String)
    case rpcError(String)

    var description: String {
        switch self {
        case .serverNotConfigured(let serverName):
            return "MCP server is not configured: \(serverName)"
        case .invalidCommand(let command):
            return "MCP command is not executable: \(command)"
        case .launchFailed(let message):
            return "MCP server launch failed: \(message)"
        case .requestTimedOut(let method):
            return "MCP request timed out: \(method)"
        case .invalidResponse(let message):
            return "MCP server returned an invalid response: \(message)"
        case .rpcError(let message):
            return "MCP server returned an error: \(message)"
        }
    }
}

struct PaceMCPServerConfiguration: Decodable, Equatable {
    let command: String
    let args: [String]
    let workingDirectory: String?
    let env: [String: String]

    enum CodingKeys: String, CodingKey {
        case command
        case args
        case workingDirectory
        case cwd
        case env
    }

    init(
        command: String,
        args: [String] = [],
        workingDirectory: String? = nil,
        env: [String: String] = [:]
    ) {
        self.command = command
        self.args = args
        self.workingDirectory = workingDirectory
        self.env = env
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.command = try container.decode(String.self, forKey: .command)
        self.args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        self.workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
            ?? container.decodeIfPresent(String.self, forKey: .cwd)
        self.env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    }
}

struct PaceMCPToolCall: Equatable {
    let serverName: String
    let toolName: String
    let arguments: [String: PaceMCPJSONValue]

    var approvalDescription: String {
        let argumentSummary = arguments.keys.sorted().joined(separator: ", ")
        guard !argumentSummary.isEmpty else {
            return "\(serverName).\(toolName)"
        }
        return "\(serverName).\(toolName) with \(argumentSummary)"
    }
}

enum PaceMCPJSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: PaceMCPJSONValue])
    case array([PaceMCPJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let intValue = try? container.decode(Int.self) {
            self = .number(Double(intValue))
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .number(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let arrayValue = try? container.decode([PaceMCPJSONValue].self) {
            self = .array(arrayValue)
        } else if let objectValue = try? container.decode([String: PaceMCPJSONValue].self) {
            self = .object(objectValue)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported MCP JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var jsonObject: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues(\.jsonObject)
        case .array(let value):
            return value.map(\.jsonObject)
        case .null:
            return NSNull()
        }
    }

    var shortDisplayText: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        case .object(let value):
            return "{\(value.keys.sorted().joined(separator: ", "))}"
        case .array(let value):
            return "[\(value.count)]"
        case .null:
            return "null"
        }
    }
}

enum PaceMCPServerRegistry {
    private struct RootConfiguration: Decodable {
        let servers: [String: PaceMCPServerConfiguration]?
        let mcpServers: [String: PaceMCPServerConfiguration]?
    }

    static var configurationPaths: [URL] {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        return [
            homeDirectory.appendingPathComponent(".config/pace/mcp-servers.json"),
            homeDirectory.appendingPathComponent(".pace/mcp-servers.json")
        ]
    }

    /// Starter config written when the user creates the MCP config from
    /// Settings. Ships apple-mcp (contacts, notes, messages, mail, reminders,
    /// calendar, maps over one stdio server — handshake-verified against
    /// Pace's newline JSON-RPC dialect) so Apple-app breadth works out of the
    /// box; users add further servers by editing the same file (see
    /// mcp-servers.example.json for curated options).
    static let starterConfigurationJSON = """
    {
      "mcpServers": {
        "apple": {
          "command": "npx",
          "args": ["-y", "apple-mcp"]
        }
      }
    }
    """

    static func loadConfiguredServers() -> [String: PaceMCPServerConfiguration] {
        for configurationPath in configurationPaths {
            guard let data = try? Data(contentsOf: configurationPath) else { continue }
            guard let root = try? JSONDecoder().decode(RootConfiguration.self, from: data) else {
                print("⚠️ Pace MCP: could not decode \(configurationPath.path)")
                continue
            }
            let servers = root.servers ?? root.mcpServers ?? [:]
            if !servers.isEmpty {
                return servers
            }
        }
        return [:]
    }
}

struct PaceMCPStdioClient {
    private let serverConfigurationsProvider: () -> [String: PaceMCPServerConfiguration]
    private let requestTimeoutInSeconds: TimeInterval

    init(
        serverConfigurations: [String: PaceMCPServerConfiguration]? = nil,
        requestTimeoutInSeconds: TimeInterval = 20
    ) {
        if let serverConfigurations {
            self.serverConfigurationsProvider = { serverConfigurations }
        } else {
            self.serverConfigurationsProvider = PaceMCPServerRegistry.loadConfiguredServers
        }
        self.requestTimeoutInSeconds = requestTimeoutInSeconds
    }

    init(
        serverConfigurationsProvider: @escaping () -> [String: PaceMCPServerConfiguration],
        requestTimeoutInSeconds: TimeInterval = 20
    ) {
        self.serverConfigurationsProvider = serverConfigurationsProvider
        self.requestTimeoutInSeconds = requestTimeoutInSeconds
    }

    var configuredServerNames: [String] {
        serverConfigurationsProvider().keys.sorted()
    }

    func callTool(_ toolCall: PaceMCPToolCall) async throws -> String {
        let serverConfigurations = serverConfigurationsProvider()
        guard let serverConfiguration = serverConfigurations[toolCall.serverName] else {
            throw PaceMCPClientError.serverNotConfigured(toolCall.serverName)
        }

        let callStartedAt = Date()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                func auditMCPCall(outcome: String, outputCharacterCount: Int? = nil, detail: String? = nil) {
                    PaceAPIAuditLog.shared.record(
                        subsystem: "mcp",
                        operation: "tools/call",
                        target: "\(toolCall.serverName).\(toolCall.toolName)",
                        durationMilliseconds: Int(Date().timeIntervalSince(callStartedAt) * 1000),
                        outcome: outcome,
                        outputCharacterCount: outputCharacterCount,
                        detail: detail
                    )
                }
                do {
                    let result = try runSynchronousToolCall(
                        toolCall,
                        serverConfiguration: serverConfiguration,
                        timeoutInSeconds: requestTimeoutInSeconds
                    )
                    auditMCPCall(outcome: "ok", outputCharacterCount: result.count)
                    continuation.resume(returning: result)
                } catch {
                    auditMCPCall(
                        outcome: "error",
                        detail: String(String(describing: error).prefix(160))
                    )
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private func runSynchronousToolCall(
    _ toolCall: PaceMCPToolCall,
    serverConfiguration: PaceMCPServerConfiguration,
    timeoutInSeconds: TimeInterval
) throws -> String {
    let process = Process()
    process.executableURL = try executableURL(for: serverConfiguration.command)
    process.arguments = serverConfiguration.args

    if let workingDirectory = serverConfiguration.workingDirectory, !workingDirectory.isEmpty {
        process.currentDirectoryURL = URL(fileURLWithPath: NSString(string: workingDirectory).expandingTildeInPath)
    }

    var environment = ProcessInfo.processInfo.environment
    for (key, value) in serverConfiguration.env {
        environment[key] = value
    }
    process.environment = environment

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        throw PaceMCPClientError.launchFailed(error.localizedDescription)
    }

    let stdinHandle = stdinPipe.fileHandleForWriting
    let stdoutReader = PaceMCPLineReader(fileHandle: stdoutPipe.fileHandleForReading)
    defer {
        stdoutReader.stop()
        try? stdinHandle.close()
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    try sendJSONRPCMessage(
        [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [:],
                "clientInfo": [
                    "name": "Pace",
                    "version": "0.1"
                ]
            ]
        ],
        to: stdinHandle
    )
    _ = try readJSONRPCResponse(id: 1, from: stdoutReader, timeoutInSeconds: timeoutInSeconds)

    try sendJSONRPCMessage(
        [
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        ],
        to: stdinHandle
    )

    try sendJSONRPCMessage(
        [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": toolCall.toolName,
                "arguments": toolCall.arguments.mapValues(\.jsonObject)
            ]
        ],
        to: stdinHandle
    )

    let response = try readJSONRPCResponse(id: 2, from: stdoutReader, timeoutInSeconds: timeoutInSeconds)
    return summarizeMCPToolCallResponse(response)
}

private func executableURL(for command: String) throws -> URL {
    let expandedCommand = NSString(string: command).expandingTildeInPath
    if expandedCommand.contains("/") {
        guard FileManager.default.isExecutableFile(atPath: expandedCommand) else {
            throw PaceMCPClientError.invalidCommand(command)
        }
        return URL(fileURLWithPath: expandedCommand)
    }

    let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        .split(separator: ":")
        .map(String.init)

    for pathCandidate in pathCandidates {
        let executablePath = URL(fileURLWithPath: pathCandidate).appendingPathComponent(command).path
        if FileManager.default.isExecutableFile(atPath: executablePath) {
            return URL(fileURLWithPath: executablePath)
        }
    }

    throw PaceMCPClientError.invalidCommand(command)
}

private func sendJSONRPCMessage(_ jsonObject: [String: Any], to stdinHandle: FileHandle) throws {
    let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [])
    var newlineTerminatedData = data
    newlineTerminatedData.append(0x0A)
    try stdinHandle.write(contentsOf: newlineTerminatedData)
}

private func readJSONRPCResponse(
    id expectedID: Int,
    from stdoutReader: PaceMCPLineReader,
    timeoutInSeconds: TimeInterval
) throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(timeoutInSeconds)

    while Date() < deadline {
        for lineData in stdoutReader.drainLines() {
            guard !lineData.isEmpty else { continue }
            guard let jsonObject = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if let errorObject = jsonObject["error"] as? [String: Any] {
                throw PaceMCPClientError.rpcError(formatJSONRPCError(errorObject))
            }

            guard let responseID = jsonObject["id"] as? Int, responseID == expectedID else {
                continue
            }

            return jsonObject
        }

        Thread.sleep(forTimeInterval: 0.01)
    }

    throw PaceMCPClientError.requestTimedOut("id \(expectedID)")
}

private final class PaceMCPLineReader {
    private let fileHandle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [Data] = []

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
        self.fileHandle.readabilityHandler = { [weak self] readableHandle in
            let data = readableHandle.availableData
            guard !data.isEmpty else { return }
            self?.append(data)
        }
    }

    func stop() {
        fileHandle.readabilityHandler = nil
    }

    func drainLines() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        let currentLines = lines
        lines.removeAll()
        return currentLines
    }

    private func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            lines.append(lineData)
        }
    }
}

private func formatJSONRPCError(_ errorObject: [String: Any]) -> String {
    let codeText = (errorObject["code"] as? Int).map { "\($0): " } ?? ""
    let messageText = errorObject["message"] as? String ?? "Unknown error"
    return "\(codeText)\(messageText)"
}

private func summarizeMCPToolCallResponse(_ response: [String: Any]) -> String {
    guard let result = response["result"] as? [String: Any] else {
        return "MCP tool completed."
    }

    if let isError = result["isError"] as? Bool, isError {
        return "MCP tool reported an error: \(extractMCPContentText(from: result))"
    }

    let contentText = extractMCPContentText(from: result)
    guard !contentText.isEmpty else {
        return "MCP tool completed."
    }
    return contentText
}

private func extractMCPContentText(from result: [String: Any]) -> String {
    guard let contentArray = result["content"] as? [[String: Any]] else {
        return ""
    }

    return contentArray
        .compactMap { contentItem in
            contentItem["text"] as? String
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}
