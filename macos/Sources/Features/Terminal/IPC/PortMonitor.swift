import Foundation

/// Periodically scans for TCP ports that processes running inside Ghostty tabs
/// are listening on, and attributes each port back to the tab that opened it.
///
/// Attribution works without any libghostty process API: every Ghostty surface
/// injects `GHOSTTY_TAB_ID=<surface-uuid>` into its shell environment, which is
/// inherited by every descendant process (dev servers, etc.). So for each
/// listening PID we read its environment and map the port to that tab.
@MainActor
final class PortMonitor: ObservableObject {
    static let shared = PortMonitor()

    /// Listening ports keyed by tab (surface) UUID, sorted ascending.
    @Published private(set) var portsByTab: [UUID: [Int]] = [:]

    /// How many ports to surface per tab at most (keep the sidebar minimal).
    nonisolated private static let maxPortsPerTab = 8

    private var timer: Timer?
    private var scanning = false
    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.port-monitor", qos: .utility)

    private init() {}

    /// Ports for a given tab (surface) UUID, or nil if none.
    func ports(for tabId: UUID) -> [Int]? {
        portsByTab[tabId]
    }

    // MARK: - Lifecycle

    func start(interval: TimeInterval = 3.0) {
        guard timer == nil else { return }
        scan()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Scanning

    private func scan() {
        guard !scanning else { return }
        scanning = true
        queue.async { [weak self] in
            let result = PortMonitor.collectPorts()
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                if result != self.portsByTab {
                    self.portsByTab = result
                }
            }
        }
    }

    // MARK: - Collection (runs off the main thread)

    nonisolated private static func collectPorts() -> [UUID: [Int]] {
        // 1. All listening TCP sockets -> { pid: {ports} }
        guard let lsofOut = run("/usr/sbin/lsof",
                                ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"]) else {
            return [:]
        }

        var portsByPid: [Int32: Set<Int>] = [:]
        var currentPid: Int32?
        lsofOut.enumerateLines { line, _ in
            guard let tag = line.first else { return }
            let rest = line.dropFirst()
            switch tag {
            case "p":
                currentPid = Int32(rest)
            case "n":
                if let pid = currentPid, let port = port(fromName: rest) {
                    portsByPid[pid, default: []].insert(port)
                }
            default:
                break
            }
        }

        guard !portsByPid.isEmpty else { return [:] }

        // 2. Map each listening pid -> tab UUID by reading its environment for
        //    the injected GHOSTTY_TAB_ID. `ps eww` prints the full environment
        //    after the command for each process.
        let pidList = portsByPid.keys.map(String.init).joined(separator: ",")
        guard let psOut = run("/bin/ps", ["eww", "-p", pidList]) else { return [:] }

        var tabByPid: [Int32: UUID] = [:]
        psOut.enumerateLines { line, _ in
            let trimmed = line.drop(while: { $0 == " " })
            guard let pidToken = trimmed.split(
                    separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first,
                  let pid = Int32(pidToken),
                  let marker = line.range(of: "GHOSTTY_TAB_ID=") else { return }
            let value = line[marker.upperBound...].prefix(while: { !$0.isWhitespace })
            if let uuid = UUID(uuidString: String(value)) {
                tabByPid[pid] = uuid
            }
        }

        // 3. Combine: port -> pid -> tab.
        var result: [UUID: Set<Int>] = [:]
        for (pid, ports) in portsByPid {
            guard let tabId = tabByPid[pid] else { continue }
            result[tabId, default: []].formUnion(ports)
        }

        return result.mapValues { Array($0).sorted().prefix(maxPortsPerTab).map { $0 } }
    }

    /// Extract the port number from an lsof name field such as `127.0.0.1:3000`,
    /// `*:5145`, or `[::1]:8080`.
    nonisolated private static func port(fromName name: Substring) -> Int? {
        guard let colon = name.lastIndex(of: ":") else { return nil }
        let portStr = name[name.index(after: colon)...]
        guard let port = Int(portStr), port > 0, port <= 65535 else { return nil }
        return port
    }

    /// Run a command and capture stdout as a UTF-8 string. Returns nil on failure.
    nonisolated private static func run(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
