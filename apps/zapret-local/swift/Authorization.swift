import Foundation
import Security
import Darwin

enum HelperInstaller {
    /// Authorization Services is used only for the one-time launchd installation.
    /// Normal proxy operations use the restricted local helper protocol.
    static func install() throws {
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("zapret-helper"),
              let resources = Bundle.main.resourceURL?.appendingPathComponent("engine"),
              FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("manifest.json").path) else {
            throw ProxyError("В приложении отсутствует сетевой помощник")
        }
        var authorization: AuthorizationRef?
        try check(AuthorizationCreate(nil, nil, [], &authorization))
        guard let authorization else { throw ProxyError("Не удалось запросить разрешение macOS") }
        defer { AuthorizationFree(authorization, []) }
        try "system.privilege.admin".withCString { right in
            var item = AuthorizationItem(name: right, valueLength: 0, value: nil, flags: 0)
            try withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                try check(AuthorizationCopyRights(authorization, &rights, nil,
                    [.interactionAllowed, .extendRights, .preAuthorize], nil))
            }
        }
        // The deprecated API remains supported for installers. It is used only
        // to install our fixed launchd service, never as a general command runner.
        typealias Execute = @convention(c) (AuthorizationRef, UnsafePointer<CChar>, AuthorizationFlags,
            UnsafePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?) -> OSStatus
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AuthorizationExecuteWithPrivileges") else {
            throw ProxyError("Эта версия macOS не поддерживает установку помощника")
        }
        let execute = unsafeBitCast(symbol, to: Execute.self)
        let strings = ["--install", "--uid", String(getuid()), "--resources", resources.path]
        var arguments = strings.map { strdup($0) }
        arguments.append(nil)
        defer { for pointer in arguments { free(pointer) } }
        var pipe: UnsafeMutablePointer<FILE>?
        try executable.path.withCString { path in
            try arguments.withUnsafeBufferPointer { argv in
                try check(execute(authorization, path, [], argv.baseAddress, &pipe))
            }
        }
        guard let pipe else { throw ProxyError("Не удалось получить результат установки") }
        defer { fclose(pipe) }
        let fd = fileno(pipe)
        let deadline = Date().addingTimeInterval(120)
        var output = Data()
        while Date() < deadline {
            var event = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&event, 1, 500)
            if ready < 0 && errno == EINTR { continue }
            if ready < 0 { throw ProxyError("Не удалось прочитать результат установки") }
            if ready == 0 { continue }
            var buffer = [UInt8](repeating: 0, count: 2048)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ProxyError("Установка помощника прервана") }
            output.append(contentsOf: buffer.prefix(count))
            guard output.count <= 65_536 else { throw ProxyError("Некорректный результат установки") }
        }
        guard Date() < deadline else { throw ProxyError("Установка заняла слишком много времени") }
        // Do not infer success just from a successful authorization: the installer
        // itself must report success, then the service is authenticated separately.
        if let line = String(data: output, encoding: .utf8)?.split(separator: "\n").last,
           let reply = try? JSONDecoder().decode(HelperReply.self, from: Data(line.utf8)) {
            guard reply.ok else { throw ProxyError(reply.error ?? "Не удалось установить помощник") }
        } else {
            throw ProxyError("Помощник не подтвердил установку")
        }
    }

    private static func check(_ status: OSStatus) throws {
        if status == errAuthorizationCanceled { throw ProxyError("Установка отменена") }
        guard status == errAuthorizationSuccess else {
            throw ProxyError("macOS не разрешила установку (код \(status))")
        }
    }
}
