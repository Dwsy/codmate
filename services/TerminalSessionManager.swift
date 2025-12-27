import Darwin
import Foundation

#if canImport(SwiftTerm)
  import SwiftTerm

  private final class TerminalShellBootstrapper {
    static let shared = TerminalShellBootstrapper()
    private let queue = DispatchQueue(label: "io.codmate.terminal.zsh", qos: .userInitiated)
    private var cachedDirectory: URL?

    private init() {}

    func ensureBootstrapDirectory() -> URL {
      if let cachedDirectory { return cachedDirectory }
      return queue.sync {
        if let cachedDirectory { return cachedDirectory }
        let appSupport = FileManager.default.urls(
          for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let zdotdir = appSupport.appendingPathComponent("CodMate/ZDOTDIR", isDirectory: true)
        try? FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)

        let zshenvURL = zdotdir.appendingPathComponent(".zshenv", isDirectory: false)
        // Always overwrite to ensure latest paths (like .bun) are available
        let injectedPATH = CLIEnvironment.buildInjectedPATH()
        let content = """
          # CodMate App Store sandbox bootstrap
          # Ensure common CLI paths are available to embedded zsh
          export PATH="\(injectedPATH)"
          export LANG="${LANG:-zh_CN.UTF-8}"
          export LC_ALL="${LC_ALL:-zh_CN.UTF-8}"
          export LC_CTYPE="${LC_CTYPE:-zh_CN.UTF-8}"
          export TERM="${TERM:-xterm-256color}"
          """
        try? content.write(to: zshenvURL, atomically: true, encoding: .utf8)

        let zshrcURL = zdotdir.appendingPathComponent(".zshrc", isDirectory: false)
        if !FileManager.default.fileExists(atPath: zshrcURL.path) {
          let rc = """
            # CodMate embedded terminal minimal rc
            # Keep this file minimal to avoid sandbox access to user dotfiles/plugins.
            # Guarantee Homebrew bins appear before system default.
            setopt NO_MONITOR
            case ":$PATH:" in
              *:/opt/homebrew/bin:*) ;;
              *) export PATH="/opt/homebrew/bin:$PATH" ;;
            esac
            case ":$PATH:" in
              *:/usr/local/bin:*) ;;
              *) export PATH="/usr/local/bin:$PATH" ;;
            esac
            """
          try? rc.write(to: zshrcURL, atomically: true, encoding: .utf8)
        }

        cachedDirectory = zdotdir
        return zdotdir
      }
    }
  }

  @MainActor
  final class TerminalSessionManager {
    static let shared = TerminalSessionManager()
    static let standardExecutablePrefix = CLIEnvironment.buildBasePATH()
    // Keyed by terminalKey (not session id). Allows multiple panes per session.
    private var sessions: [String: HeadlessTerminalSession] = [:]
    private var bootstrapped: Set<String> = []
    private var lastUsedAt: [String: Date] = [:]
    private var startedAt: [String: Date] = [:]
    private var nudgedSlash: Set<String> = []
    private var consoleModeKeys: Set<String> = []
    private weak var activeTerminalView: CodMateTerminalView?
    private var activeSessionKey: String?
    private let shellBootstrapper = TerminalShellBootstrapper.shared
    private let processInfoQueue = DispatchQueue(
      label: "io.codmate.terminal.procinfo", qos: .userInitiated)
    private let maxCachedSessions = 12
    private let baseScrollbackLines = 6_000
    private let boostedScrollbackLines = 120_000
    private let scrollbackShrinkDelay: TimeInterval = 180
    private struct ScrollbackState {
      var currentLines: Int
      var shrinkTask: Task<Void, Never>?
      var pinned: Bool
    }
    private var scrollbackStates: [String: ScrollbackState] = [:]

    private init() {}

    struct ConsoleSpec {
      var executable: String  // e.g. "codex" or "claude" (resolved via /usr/bin/env)
      var args: [String]  // e.g. ["resume", "<id>"]
      var cwd: String  // working directory
      var env: [String: String]  // environment overlay
    }

    func session(
      for terminalKey: String,
      initialCommands: String,
      consoleSpec: ConsoleSpec? = nil
    ) -> HeadlessTerminalSession {
      if let existing = sessions[terminalKey] {
        if existing.process.running {
          lastUsedAt[terminalKey] = Date()
          setConsoleMode(for: terminalKey, isConsole: consoleSpec != nil)
          if initialCommands.localizedCaseInsensitiveContains("resume") {
            ensureScrollback(for: terminalKey, minimumLines: boostedScrollbackLines, pin: true)
          }
          return existing
        } else {
          NSLog("📺 [TerminalSessionManager] Process died for key %@, recreating", terminalKey)
          sessions.removeValue(forKey: terminalKey)
          bootstrapped.remove(terminalKey)
          consoleModeKeys.remove(terminalKey)
          startedAt.removeValue(forKey: terminalKey)
        }
      }

      // Ensure SwiftTerm disables OSC 10/11 color query responses for embedded sessions
      setenv("CODEX_DISABLE_COLOR_QUERY", "1", 1)

      let wantsBoostedScrollback = initialCommands.localizedCaseInsensitiveContains("resume")
      var options = TerminalOptions.default
      options.scrollback = wantsBoostedScrollback ? boostedScrollbackLines : baseScrollbackLines
      let session = HeadlessTerminalSession(sessionKey: terminalKey, options: options)
      session.onProcessTerminated = { [weak self] _ in
        Task { @MainActor in
          self?.bootstrapped.remove(terminalKey)
          self?.startedAt.removeValue(forKey: terminalKey)
          self?.notifyTerminalSessionsUpdated()
        }
      }
      scrollbackStates[terminalKey] = ScrollbackState(
        currentLines: options.scrollback, shrinkTask: nil, pinned: wantsBoostedScrollback)

      let (_, envArray) = buildEnvironment(consoleSpec: consoleSpec)
      if let spec = consoleSpec {
        let launch = resolvedExecutable(for: spec)
        session.startProcess(
          executable: launch.executable,
          args: launch.args,
          environment: envArray,
          execName: nil,
          currentDirectory: spec.cwd
        )
      } else {
        session.startProcess(
          executable: "/bin/zsh",
          args: ["-l"],
          environment: envArray,
          execName: nil,
          currentDirectory: nil
        )
      }

      sessions[terminalKey] = session
      let now = Date()
      lastUsedAt[terminalKey] = now
      startedAt[terminalKey] = now
      setConsoleMode(for: terminalKey, isConsole: consoleSpec != nil)
      pruneLRU(keepingMostRecent: maxCachedSessions)
      NSLog(
        "📺 [TerminalSessionManager] Created terminal for key %@, PID: %d", terminalKey,
        session.process.shellPid)
      scheduleScrollbackShrink(for: terminalKey)
      if wantsBoostedScrollback {
        ensureScrollback(for: terminalKey, minimumLines: boostedScrollbackLines, pin: true)
      }
      notifyTerminalSessionsUpdated()
      return session
    }

    func stop(key: String, sync: Bool = false) {
      guard let session = sessions.removeValue(forKey: key) else {
        return
      }

      consoleModeKeys.remove(key)
      startedAt.removeValue(forKey: key)

      // Multi-stage termination to ensure all processes (codex/claude and descendants) are cleaned up

      // CRITICAL: Save PID BEFORE calling terminate() which clears it!
      let pid: pid_t
      let hasRunningProcess: Bool

      let proc = session.process
      if proc.running {
        pid = proc.shellPid
        hasRunningProcess = pid > 0
      } else {
        pid = 0
        hasRunningProcess = false
      }

      if hasRunningProcess {
        // Stage 1: Send signals BEFORE closing PTY
        let pgid = getpgid(pid)
        NSLog("🛑 [TerminalSessionManager] Stopping session %@: PID=%d PGID=%d", key, pid, pgid)

        if pgid > 0 && pgid != getpgrp() {
          // Send SIGTERM to entire process group (negative pgid)
          _ = kill(-pgid, SIGTERM)
        } else if pgid <= 0 {
          // Fallback: if getpgid failed, try direct pid
          _ = kill(pid, SIGTERM)
        }

        // Stage 2: Now close PTY (this sends SIGHUP)
        session.terminate()

        // Stage 3: Wait and force kill if needed
        let killProcess = {
          // Wait up to 300ms for graceful exit (shorter for faster response)
          let deadline = Date().addingTimeInterval(0.3)
          var exited = false

          while Date() < deadline && !exited {
            // Check if process still exists (kill with signal 0)
            if kill(pid, 0) != 0 && errno == ESRCH {
              exited = true
              break
            }
            usleep(30_000)  // 30ms
          }

          // If still alive, force kill immediately and aggressively
          if !exited {
            let currentPgid = getpgid(pid)

            // Kill the entire process group with SIGKILL
            if currentPgid > 0 && currentPgid != getpgrp() {
              _ = kill(-currentPgid, SIGKILL)
            }

            // Also direct kill to the shell PID
            _ = kill(pid, SIGKILL)

            // Find and kill all children of this process
            self.killProcessTree(rootPid: pid)

            // Wait a bit for SIGKILL to take effect
            usleep(150_000)  // 150ms

            // Final check and reap
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
          }

          // Mark process as terminated in LocalProcess
          proc.markAsTerminated()
        }

        if sync {
          // Synchronous execution: block until process is killed
          killProcess()
        } else {
          // Asynchronous execution: for UI responsiveness
          DispatchQueue.global(qos: .userInitiated).async {
            killProcess()
          }
        }
      } else {
        // No running process, just close PTY
        session.terminate()
      }

      bootstrapped.remove(key)
      lastUsedAt.removeValue(forKey: key)
      nudgedSlash.remove(key)
      scrollbackStates.removeValue(forKey: key)
      notifyTerminalSessionsUpdated()
      if activeSessionKey == key {
        activeSessionKey = nil
        activeTerminalView = nil
      }
    }

    /// Aggressively kill a process tree by finding and killing all descendants
    /// Uses sysctl for fast, non-blocking process tree query
    private func killProcessTree(rootPid: pid_t) {
      processInfoQueue.sync {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length: size_t = 0

        guard sysctl(&name, u_int(name.count), nil, &length, nil, 0) == 0 else {
          kill(rootPid, SIGKILL)
          return
        }

        let count = length / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)

        guard sysctl(&name, u_int(name.count), &procs, &length, nil, 0) == 0 else {
          kill(rootPid, SIGKILL)
          return
        }

        let actualCount = length / MemoryLayout<kinfo_proc>.stride
        var children: [pid_t: [pid_t]] = [:]

        for i in 0..<actualCount {
          let proc = procs[i]
          let pid = proc.kp_proc.p_pid
          let ppid = proc.kp_eproc.e_ppid
          children[ppid, default: []].append(pid)
        }

        var toKill: [pid_t] = [rootPid]
        var visited: Set<pid_t> = []
        var killCount = 0

        while !toKill.isEmpty {
          let pid = toKill.removeFirst()
          guard !visited.contains(pid) else { continue }
          visited.insert(pid)
          kill(pid, SIGKILL)
          killCount += 1
          if let childPids = children[pid] {
            toKill.append(contentsOf: childPids)
          }
        }

        if killCount > 1 {
          NSLog("   🌳 Killed process tree: %d processes", killCount)
        }
      }
    }

    /// Helper to check if a process is actually running
    func isProcessRunning(pid: pid_t) -> Bool {
      guard pid > 0 else { return false }
      // kill with signal 0 checks if process exists without sending a signal
      return kill(pid, 0) == 0 || errno != ESRCH
    }

    /// Check if a shell has active child processes (like codex, claude, etc.)
    /// Returns true only if there are running children, false if shell is idle
    /// Uses sysctl for fast, non-blocking process tree query
    private func hasActiveChildren(shellPid: pid_t) -> Bool {
      guard shellPid > 0 else { return false }
      return processInfoQueue.sync {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length: size_t = 0

        guard sysctl(&name, u_int(name.count), nil, &length, nil, 0) == 0 else {
          return true
        }

        let count = length / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)

        guard sysctl(&name, u_int(name.count), &procs, &length, nil, 0) == 0 else {
          return true
        }

        let actualCount = length / MemoryLayout<kinfo_proc>.stride

        for i in 0..<actualCount {
          let proc = procs[i]
          if proc.kp_eproc.e_ppid != shellPid { continue }
          let status = proc.kp_proc.p_stat
          if status == SZOMB || status == SSTOP { continue }
          return true
        }
        return false
      }
    }

    /// Check if terminal has running process (for confirmation dialog)
    /// Returns true only if there are active programs (codex, claude, etc.) running
    /// Returns false if just an idle shell waiting for input
    func hasRunningProcess(key: String) -> Bool {
      guard let session = sessions[key] else { return false }
      let proc = session.process
      guard proc.running && isProcessRunning(pid: proc.shellPid) else { return false }

      // Shell exists, but check if it has active children
      return hasActiveChildren(shellPid: proc.shellPid)
    }

    /// Check if any terminal session has a running process
    func hasAnyRunningProcesses() -> Bool {
      for (_, session) in sessions {
        let proc = session.process
        if proc.running, isProcessRunning(pid: proc.shellPid) {
          if hasActiveChildren(shellPid: proc.shellPid) { return true }
        }
      }
      return false
    }

    func stopAll(withPrefix prefix: String, sync: Bool = false) {
      let keys = sessions.keys.filter { $0.hasPrefix(prefix) }
      for k in keys { stop(key: k, sync: sync) }
    }

    // Best-effort pruning when too many panes exist. Does not stop the most recently used key.
    func pruneLRU(keepingMostRecent keep: Int) {
      let sorted = lastUsedAt.sorted(by: { $0.value > $1.value }).map { $0.key }
      guard sorted.count > keep else { return }
      for k in sorted.dropFirst(keep) { stop(key: k) }
    }

    // Rename a running terminal key without restarting the underlying process/view.
    // Useful when a "new" session is created from an anchor and we learn the final session id later.
    func rekey(from oldKey: String, to newKey: String) {
      guard oldKey != newKey else { return }
      guard let session = sessions.removeValue(forKey: oldKey) else { return }
      // If destination exists, stop the old one to avoid duplicate shells
      if let existing = sessions.removeValue(forKey: newKey) {
        existing.terminate()
      }
      sessions[newKey] = session
      if let state = scrollbackStates.removeValue(forKey: oldKey) {
        scrollbackStates[newKey] = state
      }
      let now = Date()
      lastUsedAt[newKey] = now
      lastUsedAt.removeValue(forKey: oldKey)
      // Transfer bootstrap mark so initial commands won't be re-injected for the new key
      if bootstrapped.contains(oldKey) {
        bootstrapped.remove(oldKey)
        bootstrapped.insert(newKey)
      }
      if nudgedSlash.contains(oldKey) {
        nudgedSlash.remove(oldKey)
      }
      if consoleModeKeys.contains(oldKey) {
        consoleModeKeys.remove(oldKey)
        consoleModeKeys.insert(newKey)
      } else {
        consoleModeKeys.remove(newKey)
      }
      if activeSessionKey == oldKey {
        activeSessionKey = newKey
      }
    }

    /// Schedules a tiny "/" then backspace keystroke to nudge Codex to redraw cleanly after resume.
    /// This helps clear any residual artifacts without changing shell state.
    func scheduleSlashNudge(forKey key: String, delay: TimeInterval = 1.0) {
      if nudgedSlash.contains(key) { return }
      nudgedSlash.insert(key)
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self = self, let session = self.sessions[key] else { return }
        session.send(data: [UInt8(47), UInt8(127)][...])
      }
    }

    func isConsoleMode(key: String) -> Bool {
      consoleModeKeys.contains(key)
    }

    private func setConsoleMode(for key: String, isConsole: Bool) {
      if isConsole {
        consoleModeKeys.insert(key)
      } else {
        consoleModeKeys.remove(key)
      }
    }

    func registerActiveView(_ view: CodMateTerminalView?, sessionKey: String?) {
      activeTerminalView = view
      activeSessionKey = sessionKey
    }

    func currentActiveSessionKey() -> String? {
      activeSessionKey
    }

    func detachView(for key: String) {
      sessions[key]?.detachView()
    }

    func shouldBootstrap(key: String) -> Bool {
      if bootstrapped.contains(key) { return false }
      bootstrapped.insert(key)
      return true
    }

    // Intentionally no global "copy-all" API exposed; large clipboard operations can be costly.

    /// Sends raw text to the running terminal identified by key, if present.
    /// Does not append a newline; callers control execution semantics.
    func send(to key: String, text: String) {
      guard let session = sessions[key] else { return }
      let data = Array(text.utf8)
      session.send(data: data[...])
    }

    /// Sends a command and appends a carriage return (CR) to execute it immediately.
    /// Uses a single send call to avoid timing issues where the return
    /// could be processed before the command text by the PTY.
    func execute(key: String, command: String) {
      guard let session = sessions[key] else { return }
      // Terminals typically treat Return as CR (\r, 0x0D), not LF (\n, 0x0A).
      // Some shells might ignore a bare LF for execution. Always ensure a CR is sent.
      let needsCR = !(command.hasSuffix("\r") || command.hasSuffix("\n"))
      if needsCR {
        session.send(data: Array(command.utf8)[...])
        session.send(data: [UInt8(13)][...])  // CR
      } else if command.hasSuffix("\n") {
        // Replace trailing LF with CR to emulate Return key precisely.
        let trimmed = String(command.dropLast())
        session.send(data: Array(trimmed.utf8)[...])
        session.send(data: [UInt8(13)][...])
      } else {
        // Already has CR
        session.send(data: Array(command.utf8)[...])
      }
    }

    /// Attempts to focus the terminal view to receive keyboard input.
    func focus(key: String) {
      guard let activeTerminalView, activeSessionKey == key else { return }
      activeTerminalView.window?.makeFirstResponder(activeTerminalView)
    }

    /// Clears screen and scrollback similar to Cmd+K in Terminal.
    /// Achieved by executing: printf '\e[3J'; clear
    func clear(key: String) {
      guard sessions[key] != nil else { return }
      let seq = "printf '\u{001B}[3J'; clear\n"
      send(to: key, text: seq)
    }

    private func ensureScrollback(for key: String, minimumLines: Int, pin: Bool = false) {
      guard var state = scrollbackStates[key], let session = sessions[key] else { return }
      var didChange = false
      if state.currentLines < minimumLines {
        session.terminal.changeHistorySize(minimumLines)
        state.currentLines = minimumLines
        didChange = true
      }
      if pin && !state.pinned {
        state.pinned = true
        didChange = true
      }
      if didChange {
        state.shrinkTask?.cancel()
        state.shrinkTask = nil
        scrollbackStates[key] = state
      }
    }

    private func scheduleScrollbackShrink(for key: String) {
      guard var state = scrollbackStates[key] else { return }
      if state.pinned { return }
      state.shrinkTask?.cancel()
      state.shrinkTask = Task { [weak self] in
        guard let self = self else { return }
        let delay = UInt64(self.scrollbackShrinkDelay * 1_000_000_000)
        try? await Task.sleep(nanoseconds: delay)
        await MainActor.run {
          self.shrinkScrollbackToBase(for: key)
        }
      }
      scrollbackStates[key] = state
    }

    private func shrinkScrollbackToBase(for key: String) {
      guard var state = scrollbackStates[key], state.currentLines > baseScrollbackLines,
        let session = sessions[key]
      else { return }
      if state.pinned { return }
      session.terminal.changeHistorySize(baseScrollbackLines)
      state.currentLines = baseScrollbackLines
      state.shrinkTask?.cancel()
      state.shrinkTask = nil
      scrollbackStates[key] = state
    }

    private func handleScrollActivity(for key: String) {
      scheduleScrollbackShrink(for: key)
    }

    func recordScrollActivity(for key: String) {
      handleScrollActivity(for: key)
    }

    // Waits for a reasonable terminal size before injecting the initial commands to avoid
    // the appearance of 1–2 column widths and "typing" artifacts.
    func injectInitialCommandsOnce(
      key: String, view: CodMateTerminalView, payload: String
    ) {
      let timeout: TimeInterval = 1.5
      let checkInterval: UInt64 = 8_000_000  // 8ms in nanoseconds

      Task { @MainActor in
        let deadline = Date().addingTimeInterval(timeout)

        // Wait for terminal to be ready (window visible and sufficient size)
        while Date() < deadline {
          guard view.window != nil else {
            try? await Task.sleep(nanoseconds: checkInterval)
            continue
          }

          let cols = view.getTerminal().cols
          let width = view.bounds.width

          if cols >= 40 && width >= 80 {
            // Ready - inject commands atomically
            let text = payload.hasSuffix("\n") ? payload : (payload + "\n")
            view.send(txt: text)
            return
          }

          try? await Task.sleep(nanoseconds: checkInterval)
        }

        // Timeout fallback - inject anyway
        let text = payload.hasSuffix("\n") ? payload : (payload + "\n")
        view.send(txt: text)
      }
    }

    private func buildEnvironment(consoleSpec: ConsoleSpec?) -> ([String: String], [String]) {
      var env = ProcessInfo.processInfo.environment
      if let old = env["PATH"], !old.isEmpty {
        env["PATH"] = Self.standardExecutablePrefix + ":" + old
      } else {
        env["PATH"] = Self.standardExecutablePrefix
      }
      env["LANG"] = env["LANG"] ?? "zh_CN.UTF-8"
      env["LC_ALL"] = env["LC_ALL"] ?? "zh_CN.UTF-8"
      env["LC_CTYPE"] = env["LC_CTYPE"] ?? "zh_CN.UTF-8"
      env["TERM"] = env["TERM"] ?? "xterm-256color"
      env["SHELL"] = "/bin/zsh"
      if consoleSpec == nil {
        let zdotdir = shellBootstrapper.ensureBootstrapDirectory()
        env["ZDOTDIR"] = zdotdir.path
      }
      if let overlay = consoleSpec?.env {
        for (k, v) in overlay { env[k] = v }
      }
      return (env, env.map { "\($0.key)=\($0.value)" })
    }

    private func resolvedExecutable(for spec: ConsoleSpec) -> (executable: String, args: [String]) {
      if spec.executable.contains("/") {
        return (spec.executable, spec.args)
      }
      var args = spec.args
      args.insert(spec.executable, at: 0)
      return ("/usr/bin/env", args)
    }

    static func executableExists(_ name: String) -> Bool {
      let fm = FileManager.default
      let envPATH = ProcessInfo.processInfo.environment["PATH"] ?? ""
      let combined =
        envPATH.isEmpty ? standardExecutablePrefix : standardExecutablePrefix + ":" + envPATH
      for raw in combined.split(separator: ":") {
        guard !raw.isEmpty else { continue }
        var dir = String(raw)
        if dir.hasPrefix("~") {
          dir = (dir as NSString).expandingTildeInPath
        } else if dir.hasPrefix("$HOME") {
          dir = dir.replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
        }
        let candidate = (dir as NSString).appendingPathComponent(name)
        if fm.isExecutableFile(atPath: candidate) {
          return true
        }
      }
      return false
    }

    // MARK: - Active Sessions Query

    struct ActiveSessionInfo {
      let terminalKey: String
      let pid: Int32
      let startedAt: Date
      let isConsoleMode: Bool
    }

    func getActiveSessions() -> [ActiveSessionInfo] {
      return sessions.compactMap { key, session in
        guard session.process.running else { return nil }
        let startDate = startedAt[key] ?? lastUsedAt[key] ?? Date()
        let isConsole = consoleModeKeys.contains(key)
        return ActiveSessionInfo(
          terminalKey: key,
          pid: session.process.shellPid,
          startedAt: startDate,
          isConsoleMode: isConsole
        )
      }.sorted { $0.startedAt > $1.startedAt }
    }

    func getActiveSessionsCount() -> Int {
      return sessions.values.filter { $0.process.running }.count
    }

    private func notifyTerminalSessionsUpdated() {
      NotificationCenter.default.post(name: .codMateTerminalSessionsUpdated, object: nil)
    }
  }

#endif
