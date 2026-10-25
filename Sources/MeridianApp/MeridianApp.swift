import AppKit
import Darwin
import MeridianCore
import MeridianVM
import SwiftUI

@main
struct MeridianApp: App {
    @StateObject private var model: AppModel

    init() {
        if CommandLine.arguments.contains("--check-virtualization") {
            let code = VirtualizationProbe.run()
            Darwin.exit(Int32(code))
        }
        if CommandLine.arguments.contains("--boot-smoke") {
            let code = VirtualizationProbe.bootSmoke()
            Darwin.exit(Int32(code))
        }
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.stopAll()
                }
        }
        .defaultSize(width: 1120, height: 740)

        WindowGroup(id: "sandbox", for: UUID.self) { $id in
            if let id {
                SandboxRoot(projectID: id)
                    .environmentObject(model)
                    .frame(minWidth: 900, minHeight: 560)
            }
        }
        .defaultSize(width: 1180, height: 780)
    }
}

enum VirtualizationProbe {
    static func run() -> Int32 {
        guard LinuxVM.isSupported else {
            fputs("virtualization unsupported\n", stderr)
            return 2
        }
        guard let image = GuestImageStore.load() else {
            fputs("guest image missing\n", stderr)
            return 3
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meridian-probe-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let vm = LinuxVM(
                projectID: UUID(),
                kernel: image.kernel,
                initramfs: image.initramfs,
                mirrorURL: directory,
                machineDirectory: directory.appendingPathComponent("machine", isDirectory: true)
            )
            let config = try vm.makeConfiguration()
            try config.validate()
            fputs("virtualization ok\n", stdout)
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static func bootSmoke() -> Int32 {
        guard LinuxVM.isSupported else {
            fputs("virtualization unsupported\n", stderr)
            return 2
        }
        guard let image = GuestImageStore.load() else {
            fputs("guest image missing\n", stderr)
            return 3
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meridian-boot-\(UUID().uuidString)", isDirectory: true)
        let box = BootCapture()
        let ready = BootReady()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            box.code = await runBoot(image: image, directory: directory, box: box, ready: ready)
            semaphore.signal()
        }
        semaphore.wait()
        return box.code
    }

    private static func runBoot(image: LoadedGuestImage, directory: URL, box: BootCapture, ready: BootReady) async -> Int32 {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let vm = LinuxVM(
                projectID: UUID(),
                kernel: image.kernel,
                initramfs: image.initramfs,
                mirrorURL: directory,
                machineDirectory: directory.appendingPathComponent("machine", isDirectory: true)
            )
            let channel = GuestChannel()
            vm.onSerial = { box.append($0) }
            vm.onAccept = { channel.accept($0) }
            channel.onReady = { open in
                if open.ready == true {
                    ready.mark(open.workspace == true)
                } else {
                    channel.sendHello(github: false)
                }
            }
            try await vm.start()
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline && !ready.isDone {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            let log = box.text()
            fputs(log, stdout)
            channel.close()
            await vm.stop()
            if ready.isDone {
                fputs("boot ok workspace=\(ready.workspace ? 1 : 0)\n", stdout)
                return 0
            }
            fputs("boot timed out\n", stderr)
            return 1
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            fputs(box.text(), stdout)
            return 1
        }
    }
}

final class BootCapture: @unchecked Sendable {
    var code: Int32 = 1
    private let lock = NSLock()
    private var serial = ""

    func append(_ text: String) {
        lock.lock()
        serial.append(text)
        if serial.count > 60000 {
            serial.removeFirst(serial.count - 60000)
        }
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return serial
    }
}

final class BootReady: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private(set) var workspace = false

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    func mark(_ workspace: Bool) {
        lock.lock()
        self.workspace = workspace
        done = true
        lock.unlock()
    }
}
