import Darwin
import Foundation

enum CommandProcess {
    private static let maxStdoutBytes: UInt64 = 16 * 1024 * 1024
    private static let maxStderrBytes: UInt64 = 4 * 1024 * 1024

    private struct PipeCapture {
        var descriptor: Int32
        let limit: UInt64
        let tailLimit: Int?
        private(set) var byteCount: UInt64 = 0
        private(set) var data = Data()

        mutating func drain() throws -> Bool {
            guard descriptor >= 0 else { return false }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count > 0 {
                    let amount = UInt64(count)
                    byteCount += amount
                    if let tailLimit {
                        data.append(contentsOf: buffer.prefix(count))
                        if data.count > tailLimit { data.removeFirst(data.count - tailLimit) }
                    } else {
                        let remaining = Int(max(0, limit - UInt64(data.count)))
                        if remaining > 0 { data.append(contentsOf: buffer.prefix(min(count, remaining))) }
                    }
                    return byteCount > limit
                }
                if count == 0 {
                    close()
                    return false
                }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return false }
                throw TranscriptionCommandError("could not read command output: \(String(cString: strerror(errno)))")
            }
        }

        mutating func close() {
            guard descriptor >= 0 else { return }
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    static func executable(at path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.contains("\0") else {
            throw TranscriptionCommandError("command executable must be an absolute path (or begin with ~/)")
        }
        return URL(fileURLWithPath: expanded)
    }

    static func checkExecutable(_ executable: URL) throws {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: executable.path, isDirectory: &directory),
            !directory.boolValue, FileManager.default.isExecutableFile(atPath: executable.path)
        else { throw TranscriptionCommandError("command executable not found or not executable: \(executable.path)") }
    }

    /// Output pipes are drained together, retaining only bounded captures.
    static func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> Data {
        try checkExecutable(executable)
        let stdoutFDs = try makePipe()
        var stderrFDs: [Int32]
        do {
            stderrFDs = try makePipe()
        } catch {
            Darwin.close(stdoutFDs[0])
            Darwin.close(stdoutFDs[1])
            throw error
        }
        var stdoutRead = stdoutFDs[0]
        var stdoutWrite = stdoutFDs[1]
        var stderrRead = stderrFDs[0]
        var stderrWrite = stderrFDs[1]
        defer {
            if stdoutRead >= 0 { Darwin.close(stdoutRead) }
            if stdoutWrite >= 0 { Darwin.close(stdoutWrite) }
            if stderrRead >= 0 { Darwin.close(stderrRead) }
            if stderrWrite >= 0 { Darwin.close(stderrWrite) }
        }

        var processID: pid_t = 0
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw TranscriptionCommandError("could not initialize command process")
        }
        guard posix_spawnattr_init(&attributes) == 0 else {
            posix_spawn_file_actions_destroy(&actions)
            throw TranscriptionCommandError("could not initialize command process")
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        let actionError =
            posix_spawn_file_actions_addopen(
                &actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0
            ) | posix_spawn_file_actions_adddup2(&actions, stdoutWrite, STDOUT_FILENO)
            | posix_spawn_file_actions_adddup2(&actions, stderrWrite, STDERR_FILENO)
            | posix_spawn_file_actions_addclose(&actions, stdoutRead)
            | posix_spawn_file_actions_addclose(&actions, stderrRead)
            | posix_spawn_file_actions_addclose(&actions, stdoutWrite)
            | posix_spawn_file_actions_addclose(&actions, stderrWrite)
        guard actionError == 0,
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
            posix_spawnattr_setpgroup(&attributes, 0) == 0
        else { throw TranscriptionCommandError("could not configure command process isolation") }

        let strings = [executable.path] + arguments
        guard !strings.contains(where: { $0.contains("\0") }) else {
            throw TranscriptionCommandError("command executable and arguments cannot contain NUL characters")
        }
        var argv: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        guard argv.allSatisfy({ $0 != nil }) else {
            argv.compactMap { $0 }.forEach { free($0) }
            throw TranscriptionCommandError("could not prepare command arguments")
        }
        argv.append(nil)
        defer { argv.compactMap { $0 }.forEach { free($0) } }
        let spawnError = argv.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(
                &processID, executable.path, &actions, &attributes,
                buffer.baseAddress!, environ
            )
        }
        guard spawnError == 0 else {
            throw TranscriptionCommandError(
                "could not start \(executable.lastPathComponent): \(String(cString: strerror(spawnError)))"
            )
        }

        Darwin.close(stdoutWrite)
        stdoutWrite = -1
        Darwin.close(stderrWrite)
        stderrWrite = -1
        var stdout = PipeCapture(descriptor: stdoutRead, limit: maxStdoutBytes, tailLimit: nil)
        var stderr = PipeCapture(descriptor: stderrRead, limit: maxStderrBytes, tailLimit: 4096)
        stdoutRead = -1
        stderrRead = -1
        defer {
            stdout.close()
            stderr.close()
        }
        for descriptor in [stdout.descriptor, stderr.descriptor] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                terminate(processID)
                throw TranscriptionCommandError("could not configure command output pipes")
            }
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(timeout, 0) * 1_000_000_000)
        var status: Int32 = 0
        var processExited = false
        var timedOut = false
        var overflow: String?
        var captureError: Error?
        var terminationStarted: UInt64?
        var killed = false

        while true {
            if !processExited {
                let result = waitpid(processID, &status, WNOHANG)
                if result == processID || (result < 0 && errno == ECHILD) {
                    processExited = true
                } else if result < 0 && errno != EINTR {
                    captureError = TranscriptionCommandError(
                        "could not wait for command process: \(String(cString: strerror(errno)))"
                    )
                }
            }
            do {
                if try stdout.drain(), overflow == nil { overflow = "stdout exceeds 16 MiB output limit" }
                if try stderr.drain(), overflow == nil { overflow = "stderr exceeds 4 MiB output limit" }
            } catch {
                captureError = error
            }

            let now = DispatchTime.now().uptimeNanoseconds
            if overflow != nil || captureError != nil {
                if terminationStarted == nil {
                    terminationStarted = now
                    kill(-processID, SIGTERM)
                }
            } else if now >= deadline, terminationStarted == nil {
                timedOut = true
                terminationStarted = now
                kill(-processID, SIGTERM)
            }

            if let terminationStarted {
                if processExited && !killed {
                    kill(-processID, SIGKILL)
                    killed = true
                } else if now - terminationStarted >= 250_000_000, !killed {
                    kill(-processID, SIGKILL)
                    killed = true
                }
                if now - terminationStarted >= 1_250_000_000 {
                    stdout.close()
                    stderr.close()
                }
            }

            if processExited && stdout.descriptor < 0 && stderr.descriptor < 0 { break }

            var descriptors = [
                pollfd(fd: stdout.descriptor, events: Int16(POLLIN | POLLHUP), revents: 0),
                pollfd(fd: stderr.descriptor, events: Int16(POLLIN | POLLHUP), revents: 0),
            ]
            let pollResult = descriptors.withUnsafeMutableBufferPointer { buffer in
                poll(buffer.baseAddress, nfds_t(buffer.count), 5)
            }
            if pollResult < 0, errno != EINTR, captureError == nil {
                captureError = TranscriptionCommandError("could not poll command output: \(String(cString: strerror(errno)))")
            }
        }

        terminateRemainingGroup(processID)

        if let captureError { throw captureError }
        if let overflow {
            let detail = String(decoding: stderr.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TranscriptionCommandError(
                "\(executable.lastPathComponent) \(overflow)" + (detail.isEmpty ? "" : ": \(detail)")
            )
        }
        if timedOut {
            throw TranscriptionCommandError("\(executable.lastPathComponent) timed out after \(timeout) seconds")
        }

        let signal = status & 0x7f
        let exitStatus = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        guard exitStatus == 0 else {
            let detail = String(decoding: stderr.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback =
                detail.isEmpty
                ? String(decoding: stdout.data.suffix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                : detail
            throw TranscriptionCommandError(
                "\(executable.lastPathComponent) failed (status \(exitStatus))"
                    + (fallback.isEmpty ? "" : ": \(fallback)")
            )
        }
        return stdout.data
    }

    private static func makePipe() throws -> [Int32] {
        var descriptors = [Int32](repeating: -1, count: 2)
        let result = descriptors.withUnsafeMutableBufferPointer { Darwin.pipe($0.baseAddress!) }
        guard result == 0 else {
            throw TranscriptionCommandError("could not create command output pipe: \(String(cString: strerror(errno)))")
        }
        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFD)
            guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                let error = errno
                Darwin.close(descriptors[0])
                Darwin.close(descriptors[1])
                throw TranscriptionCommandError("could not configure command output pipe: \(String(cString: strerror(error)))")
            }
        }
        return descriptors
    }

    private static func terminate(_ processID: pid_t) {
        kill(-processID, SIGTERM)
        let graceDeadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        var status: Int32 = 0
        while DispatchTime.now().uptimeNanoseconds < graceDeadline {
            if waitpid(processID, &status, WNOHANG) == processID { break }
            usleep(10_000)
        }
        kill(-processID, SIGKILL)
        while waitpid(processID, &status, 0) < 0 && errno == EINTR {}
    }

    private static func terminateRemainingGroup(_ processID: pid_t) {
        guard processID > 1, kill(-processID, 0) == 0 || errno == EPERM else { return }
        kill(-processID, SIGTERM)
        let graceDeadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        while DispatchTime.now().uptimeNanoseconds < graceDeadline {
            if kill(-processID, 0) < 0 && errno == ESRCH { return }
            usleep(10_000)
        }
        kill(-processID, SIGKILL)
    }

    static func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

}
