import Foundation
import Network
import SwiftUI

/// A lightweight TCP proxy that forwards requests to CLIProxyAPI while
/// ensuring fresh connections by forcing "Connection: close" on all requests.
///
/// Architecture:
///   Client (Cursor/VSCode) → CLIProxyBridge (User Port) → CLIProxyAPI (Internal Port)
@MainActor
final class CLIProxyBridge: ObservableObject {
    
    // MARK: - Properties
    
    private var listener: NWListener? 
    private let stateQueue = DispatchQueue(label: "io.codmate.proxy-bridge-state")
    
    /// The port this proxy listens on (user-facing port)
    @Published private(set) var listenPort: UInt16 = 8080
    
    /// The port CLIProxyAPI runs on (internal port)
    @Published private(set) var targetPort: UInt16 = 18080
    
    /// Target host (always localhost)
    private let targetHost = "127.0.0.1"
    
    /// Whether the proxy bridge is currently running
    @Published private(set) var isRunning = false
    
    /// Last error message
    @Published private(set) var lastError: String?
    
    /// Statistics: total requests forwarded
    @Published private(set) var totalRequests: Int = 0
    
    /// Statistics: active connections count
    @Published private(set) var activeConnections: Int = 0
    
    // MARK: - Configuration
    
    /// Configure the proxy ports
    func configure(listenPort: UInt16, targetPort: UInt16) {
        self.listenPort = listenPort
        self.targetPort = targetPort
    }
    
    /// Calculate internal port from user port (offset by 10000)
    static func internalPort(from userPort: UInt16) -> UInt16 {
        let preferredPort = UInt32(userPort) + 10000
        if preferredPort <= 65535 {
            return UInt16(preferredPort)
        }
        // Fallback: use modular offset within high port range (49152-65535)
        let highPortBase: UInt16 = 49152
        let offset = userPort % 1000
        return highPortBase + offset
    }
    
    // MARK: - Lifecycle
    
    func start() {
        guard !isRunning else { return }
        lastError = nil
        
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            
            guard let port = NWEndpoint.Port(rawValue: listenPort) else {
                lastError = "Invalid port: \(listenPort)"
                return
            }
            
            listener = try NWListener(using: parameters, on: port)
            
            listener?.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(state)
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.handleNewConnection(connection)
                }
            }
            
            listener?.start(queue: .global(qos: .userInitiated))
            
        } catch {
            lastError = error.localizedDescription
        }
    }
    
    func stop() {
        stateQueue.sync {
            listener?.cancel()
            listener = nil
        }
        isRunning = false
    }
    
    // MARK: - State Handling
    
    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
        case .failed(let error):
            isRunning = false
            lastError = error.localizedDescription
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }
    
    // MARK: - Connection Handling
    
    private func handleNewConnection(_ connection: NWConnection) {
        activeConnections += 1
        totalRequests += 1
        
        let connectionId = totalRequests
        let startTime = Date()
        
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                Task { @MainActor [weak self] in self?.activeConnections -= 1 }
            } else if case .failed = state {
                Task { @MainActor [weak self] in self?.activeConnections -= 1 }
            }
        }
        
        connection.start(queue: .global(qos: .userInitiated))
        
        receiveRequest(
            from: connection,
            connectionId: connectionId,
            startTime: startTime,
            accumulatedData: Data()
        )
    }
    
    // MARK: - Request Processing
    
    private nonisolated func receiveRequest(
        from connection: NWConnection,
        connectionId: Int,
        startTime: Date,
        accumulatedData: Data
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1048576) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if error != nil {
                connection.cancel()
                return
            }
            
            guard let data = data, !data.isEmpty else {
                if isComplete { connection.cancel() }
                return
            }
            
            var newData = accumulatedData
            newData.append(data)
            
            // Simple HTTP header parsing to find double CRLF
            if let requestString = String(data: newData, encoding: .utf8),
               let headerEndRange = requestString.range(of: "\r\n\r\n") {
                
                let headerEndIndex = requestString.distance(from: requestString.startIndex, to: headerEndRange.upperBound)
                
                // Content-Length check
                let headerPart = String(requestString.prefix(headerEndIndex))
                if let lenLine = headerPart.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                   let lenVal = Int(lenLine.components(separatedBy: ":")[1].trimmingCharacters(in: .whitespaces)) {
                    
                    let bodyLen = newData.count - headerEndIndex
                    if bodyLen < lenVal {
                        // Need more data
                        self.receiveRequest(from: connection, connectionId: connectionId, startTime: startTime, accumulatedData: newData)
                        return
                    }
                }
                
                self.processRequest(data: newData, connection: connection, connectionId: connectionId)
                
            } else if !isComplete {
                self.receiveRequest(from: connection, connectionId: connectionId, startTime: startTime, accumulatedData: newData)
            } else {
                // Malformed or incomplete
                self.processRequest(data: newData, connection: connection, connectionId: connectionId)
            }
        }
    }
    
    private nonisolated func processRequest(data: Data, connection: NWConnection, connectionId: Int) {
        guard let requestString = String(data: data, encoding: .utf8) else {
            connection.cancel()
            return
        }
        
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            connection.cancel()
            return
        }
        
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 3 else {
            connection.cancel()
            return
        }
        
        let method = parts[0]
        let path = parts[1]
        let version = parts[2]
        
        // Parse Headers
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let idx = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            headers.append((k, v))
        }
        
        // Extract Body
        var body = ""
        if let bodyRange = requestString.range(of: "\r\n\r\n") {
            body = String(requestString[bodyRange.upperBound...])
        }
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let tPort = self.targetPort
            let tHost = self.targetHost
            
            self.forwardRequest(
                method: method,
                path: path,
                version: version,
                headers: headers,
                body: body,
                originalConnection: connection,
                targetPort: tPort,
                targetHost: tHost
            )
        }
    }
    
    private nonisolated func forwardRequest(
        method: String,
        path: String,
        version: String,
        headers: [(String, String)],
        body: String,
        originalConnection: NWConnection,
        targetPort: UInt16,
        targetHost: String
    ) {
        guard let port = NWEndpoint.Port(rawValue: targetPort) else {
            originalConnection.cancel()
            return
        }
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(targetHost), port: port)
        let targetConnection = NWConnection(to: endpoint, using: .tcp)
        
        targetConnection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                var req = "\(method) \(path) \(version)\r\n"
                let skip = Set(["connection", "content-length", "host", "transfer-encoding"])
                for (k, v) in headers {
                    if !skip.contains(k.lowercased()) {
                        req += "\(k): \(v)\r\n"
                    }
                }
                
                req += "Host: \(targetHost):\(targetPort)\r\n"
                req += "Connection: close\r\n"
                req += "Content-Length: \(body.utf8.count)\r\n\r\n"
                req += body
                
                if let d = req.data(using: .utf8) {
                    targetConnection.send(content: d, completion: .contentProcessed { error in
                        if error == nil {
                            self.receiveResponse(from: targetConnection, to: originalConnection)
                        } else {
                            targetConnection.cancel()
                            originalConnection.cancel()
                        }
                    })
                }
            case .failed, .cancelled:
                // Only cancel if it's an error state or explicit cancel;
                // .waiting etc. should just wait.
                if case .failed = state {
                    targetConnection.cancel()
                    originalConnection.cancel()
                } else if case .cancelled = state {
                    originalConnection.cancel()
                }
            default: break
            }
        }
        
        targetConnection.start(queue: .global(qos: .userInitiated))
    }
    
    private nonisolated func receiveResponse(from target: NWConnection, to source: NWConnection) {
        target.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if error != nil {
                target.cancel()
                source.cancel()
                return
            }
            
            if let data = data, !data.isEmpty {
                source.send(content: data, completion: .contentProcessed { error in
                    if error != nil {
                         // log?
                    }
                    if isComplete {
                        target.cancel()
                        source.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in source.cancel() }))
                    } else {
                        self.receiveResponse(from: target, to: source)
                    }
                })
            } else if isComplete {
                target.cancel()
                source.send(content: nil, isComplete: true, completion: .contentProcessed({ _ in source.cancel() }))
            }
        }
    }
}
