import Foundation

/// Runs command line tools (ffmpeg, tar, soffice...) with arguments passed as a list, never through a shell.
public enum Proc {
    public struct Result {
        public let code: Int32
        public let stdout: String
        public let stderr: String

        /// Last non-empty line of stderr, for error messages.
        public var lastError: String {
            stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? "exit code \(code)"
        }
    }

    /// Collects a pipe's output on a background thread and hands out complete lines.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var pending = Data()
        private let onLine: ((String) -> Void)?

        init(onLine: ((String) -> Void)?) { self.onLine = onLine }

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            var lines: [String] = []
            if onLine != nil {
                pending.append(chunk)
                while let nl = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<nl]
                    lines.append(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines))
                    pending.removeSubrange(pending.startIndex...nl)
                }
            }
            lock.unlock()
            for l in lines { onLine?(l) }
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    final class Waiter: @unchecked Sendable {
        let group = DispatchGroup()
    }

    static func makeProcess(_ exe: String, _ args: [String], cwd: String?, env: [String: String]?) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            p.environment = merged
        }
        p.standardInput = FileHandle.nullDevice
        return p
    }

    static func drain(_ pipe: Pipe, into c: Collector, _ group: DispatchGroup) {
        group.enter()
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                c.append(chunk)
            }
            group.leave()
        }
    }

    /// Runs a program to completion. Stdout lines go to `onLine` as they arrive. Killed after `timeout` seconds.
    public static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 0, cwd: String? = nil, env: [String: String]? = nil,
                           lowPriority: Bool = true, onErrLine: ((String) -> Void)? = nil, onLine: ((String) -> Void)? = nil) async throws -> Result {
        let p = makeProcess(exe, args, cwd: cwd, env: env)
        if lowPriority { p.qualityOfService = .utility }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let outC = Collector(onLine: onLine), errC = Collector(onLine: onErrLine)
        let w = Waiter()
        w.group.enter()
        p.terminationHandler = { _ in w.group.leave() }
        do { try p.run() } catch {
            throw OpError("Couldn't start \(P.fileName(exe)): \(error.localizedDescription)")
        }
        drain(out, into: outC, w.group)
        drain(err, into: errC, w.group)

        var timer: DispatchWorkItem?
        if timeout > 0 {
            let item = DispatchWorkItem { if p.isRunning { p.terminate() } }
            timer = item
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                w.group.notify(queue: .global()) { cont.resume() }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
        timer?.cancel()
        try Task.checkCancellation()
        return Result(code: p.terminationStatus, stdout: outC.text, stderr: errC.text)
    }

    /// Blocking version for quick probes (ffprobe, -encoders). Call off the main thread.
    public static func capture(_ exe: String, _ args: [String], timeout: TimeInterval = 30, cwd: String? = nil, env: [String: String]? = nil) -> Result {
        let p = makeProcess(exe, args, cwd: cwd, env: env)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let outC = Collector(onLine: nil), errC = Collector(onLine: nil)
        let w = Waiter()
        w.group.enter()
        p.terminationHandler = { _ in w.group.leave() }
        do { try p.run() } catch { return Result(code: -1, stdout: "", stderr: error.localizedDescription) }
        drain(out, into: outC, w.group)
        drain(err, into: errC, w.group)
        if w.group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = w.group.wait(timeout: .now() + 3)
        }
        return Result(code: p.isRunning ? -1 : p.terminationStatus, stdout: outC.text, stderr: errC.text)
    }

    /// Finds an executable in the usual places (GUI apps don't inherit the shell's PATH).
    public static func which(_ name: String) -> String? {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin", "/usr/sbin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for d in path.split(separator: ":").map(String.init) where !dirs.contains(d) { dirs.append(d) }
        }
        for d in dirs {
            let candidate = P.join(d, name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
