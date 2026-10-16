import Foundation
import Darwin

/// Same-user IPC. No network listener, shell, or UI automation is involved in transport.
final class LocalControlServer {
    static let maxRequestBytes = 1_048_576
    let socketURL: URL
    private var listener: DispatchSourceRead?
    private var lockFD: Int32 = -1
    private let workers = DispatchQueue(label: "com.scriptser.control.clients", attributes: .concurrent)
    private let slots = DispatchSemaphore(value: 16)
    private var socketIdentity: ino_t?
    private let handler: (Data) async -> Data

    static func defaultSocketURL(isDevelopmentApp: Bool) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(isDevelopmentApp ? "Scriptser-DEV" : "Scriptser")
            .appendingPathComponent("control.sock")
    }

    init(socketURL: URL, handler: @escaping (Data) async -> Data) {
        self.socketURL = socketURL
        self.handler = handler
    }

    func start() throws {
        guard listener == nil else { return }
        let parent = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
            throw ControlError("unsafe_socket", "Control directory must be owned by this user and not writable by others.")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketURL.path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ControlError("socket_path", "Control socket path is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let addressLength = socklen_t(address.sun_len)

        // The advisory lock prevents two app instances from unlinking each other's endpoint.
        let lock = open(socketURL.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw posixError() }
        guard fstat(lock, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw ControlError("already_listening", "Another Scriptser instance owns the control endpoint, or its lock is unsafe.")
        }
        lockFD = lock
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { stop(); throw posixError() }
        var bound = false
        do {
            if lstat(socketURL.path, &info) == 0 {
                guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK else {
                    throw ControlError("unsafe_socket", "Refusing to replace a non-socket control path.")
                }
                let probe = socket(AF_UNIX, SOCK_STREAM, 0)
                guard probe >= 0 else { throw posixError() }
                _ = fcntl(probe, F_SETFL, O_NONBLOCK)
                let active = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, addressLength) }
                }
                let probeError = errno
                close(probe)
                guard active != 0, probeError == ECONNREFUSED || probeError == ENOENT else {
                    throw ControlError("already_listening", "Control socket is already active.")
                }
                guard unlink(socketURL.path) == 0 else { throw posixError() }
            } else if errno != ENOENT { throw posixError() }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, addressLength) }
            }
            guard result == 0 else { throw posixError() }
            bound = true
            guard chmod(socketURL.path, 0o600) == 0, listen(fd, 16) == 0,
                  fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw posixError() }
            _ = lstat(socketURL.path, &info)
            socketIdentity = info.st_ino
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: workers)
            source.setEventHandler { [weak self] in self?.acceptClients(fd) }
            source.setCancelHandler { close(fd) }
            listener = source
            source.resume()
        } catch {
            close(fd)
            if bound { unlink(socketURL.path) }
            stop()
            throw error
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        var info = stat()
        if let identity = socketIdentity, lstat(socketURL.path, &info) == 0, info.st_ino == identity {
            unlink(socketURL.path)
        }
        socketIdentity = nil
        if lockFD >= 0 { close(lockFD); lockFD = -1 }
    }

    deinit { stop() }

    private func acceptClients(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == geteuid(),
                  slots.wait(timeout: .now()) == .success else { close(client); continue }
            let handler = self.handler
            let slots = self.slots
            workers.async {
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var one: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                do {
                    let data = try Self.readRequest(client)
                    Task {
                        let reply = await handler(data)
                        self.workers.async {
                            Self.send(reply, to: client)
                            close(client)
                            slots.signal()
                        }
                    }
                } catch {
                    Self.send(ControlAPI.failure(error), to: client)
                    close(client)
                    slots.signal()
                }
            }
        }
    }

    private static func readRequest(_ fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let remaining = max(0.001, deadline.timeIntervalSinceNow)
            var timeout = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining - floor(remaining)) * 1_000_000))
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ControlError("invalid_request", "Expected one newline-terminated JSON request within five seconds.") }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maxRequestBytes else { throw ControlError("request_too_large", "Request exceeds 1 MiB.") }
            if let end = data.firstIndex(of: 10) {
                guard data[(end + 1)...].allSatisfy({ $0 == 32 || $0 == 13 || $0 == 10 }) else {
                    throw ControlError("invalid_request", "Only one request per connection is supported.")
                }
                return data.prefix(upTo: end)
            }
        }
        throw ControlError("invalid_request", "Request timed out.")
    }

    private static func send(_ data: Data, to fd: Int32) {
        var framed = data
        framed.append(10)
        framed.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                sent += count
            }
        }
    }

    private func posixError() -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
