import Darwin
import Foundation
import KajoVM

// Module 9b: a headless development target (`kajo run <image> --protocol
// <socket>`): the image in a `ShellVM` with no views, its protocol Process
// started (`DevProtocol start`), the transport on the socket, and the main
// worker turned on the calling thread until `stop`. The token is printed by
// the caller; nothing here writes it anywhere.

public final class DevTarget: @unchecked Sendable {
    public let vm: ShellVM
    public let server: ProtocolServer
    private let wake = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopping = false

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Open the image and the socket and start serving. `onLine` sees every
    /// line the kernel emits (replies and events) before the transport
    /// routes it (kajo run prints the transcript and the stops).
    public init(image: [UInt8], options: Headless.Options = Headless.Options(), socket path: String,
                token: String = ProtocolServer.makeToken(), onLine: (@Sendable ([UInt8]) -> Void)? = nil) throws {
        if Headless.isReleaseImage(image) == true { throw Failure(description: "a release image serves no development protocol") }
        let box = ServerBox()
        let w = wake
        var callbacks = ShellCallbacks()
        callbacks.wakeMain = { w.signal() }
        callbacks.events = { line in
            onLine?(line)
            box.server?.deliver(line)
        }
        do {
            vm = try ShellVM(image: image, options: options, callbacks: callbacks)
        } catch {
            throw Failure(description: "\(error)")
        }
        let shell = vm
        do {
            server = try ProtocolServer(path: path, token: token) { conn, json in shell.postRequest(connection: conn, json: json) }
        } catch {
            vm.close()
            throw Failure(description: "\(error)")
        }
        box.server = server
        vm.openProtocol()
        vm.start()
        guard let p = vm.spawn("start", receiver: "DevProtocol") else {
            server.stop()
            vm.close()
            throw Failure(description: "the image has no DevProtocol (build it from this kernel)")
        }
        vm.waitUntilTerminated(p)
        let started = vm.result(of: p)
        vm.release(p)
        guard started == .bool(true) else {
            server.stop()
            vm.close()
            throw Failure(description: "DevProtocol start answered \(started.map { "\($0)" } ?? "nothing")")
        }
        server.start()
    }

    /// Turn the main worker until `stop` (main-affine Processes, a stopped
    /// one included, get turns; the wait between turns is bounded).
    public func run() {
        while true {
            lock.lock()
            let s = stopping
            lock.unlock()
            if s { break }
            _ = wake.wait(timeout: .now() + .milliseconds(20))
            _ = vm.runTurn(budgetNs: 4_000_000)
        }
    }

    /// From any thread: `run` returns.
    public func stop() {
        lock.lock()
        stopping = true
        lock.unlock()
        wake.signal()
    }

    /// Close the socket and the VM (after `run` returned, or instead of it).
    public func close() {
        server.stop()
        vm.close()
    }
}

final class ServerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var s: ProtocolServer?
    var server: ProtocolServer? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return s
        }
        set {
            lock.lock()
            s = newValue
            lock.unlock()
        }
    }
}
