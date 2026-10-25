import Foundation
import MeridianCore
import Virtualization

/// One lightweight Linux virtual machine. It has no network device.
/// The only way out is the virtio socket the host is listening on.
public final class LinuxVM: NSObject, VZVirtualMachineDelegate {
    public let projectID: UUID
    public let queue: DispatchQueue
    public var onSerial: (String) -> Void = { _ in }
    public var onStopped: (String?) -> Void = { _ in }
    public var onAccept: ((VZVirtioSocketConnection) -> Void)?

    private let kernel: URL
    private let initramfs: URL
    private let mirrorURL: URL
    private let machineDirectory: URL
    private var machine: VZVirtualMachine?
    private var serialIn: Pipe?
    private var serialOut: Pipe?
    private let listener = VZVirtioSocketListener()
    private var bridge: SocketBridge?

    public init(projectID: UUID, kernel: URL, initramfs: URL, mirrorURL: URL, machineDirectory: URL) {
        self.projectID = projectID
        self.kernel = kernel
        self.initramfs = initramfs
        self.mirrorURL = mirrorURL
        self.machineDirectory = machineDirectory
        self.queue = DispatchQueue(label: "meridian.vm.\(projectID.uuidString)")
        super.init()
    }

    public static var isSupported: Bool {
        VZVirtualMachine.isSupported
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.queue.async {
                do {
                    let config = try self.makeConfiguration()
                    try config.validate()
                    let vm = VZVirtualMachine(configuration: config, queue: self.queue)
                    vm.delegate = self
                    let bridge = SocketBridge { [weak self] connection in
                        self?.onAccept?(connection)
                    }
                    self.bridge = bridge
                    self.listener.delegate = bridge
                    if let socket = vm.socketDevices.first as? VZVirtioSocketDevice {
                        socket.setSocketListener(self.listener, forPort: GuestProtocol.hostPort)
                    }
                    self.machine = vm
                    vm.start { result in
                        continuation.resume(with: result)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.queue.async {
                guard let vm = self.machine, vm.canStop else {
                    continuation.resume()
                    return
                }
                vm.stop { _ in
                    continuation.resume()
                }
            }
        }
    }

    public func makeConfiguration() throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        let boot = VZLinuxBootLoader(kernelURL: kernel)
        boot.initialRamdiskURL = initramfs
        boot.commandLine = "console=hvc0 rdinit=/init loglevel=7"
        config.bootLoader = boot

        let allowedMin = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let allowedMax = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        config.cpuCount = min(allowedMax, max(allowedMin, min(4, ProcessInfo.processInfo.activeProcessorCount)))
        config.memorySize = Self.chooseMemory()

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = try loadOrCreateIdentifier()
        config.platform = platform
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        let share = VZVirtioFileSystemDeviceConfiguration(tag: "project")
        share.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: mirrorURL, readOnly: false))
        config.directorySharingDevices = [share]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        let guestInput = Pipe()
        let guestOutput = Pipe()
        serialIn = guestInput
        serialOut = guestOutput
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: guestInput.fileHandleForReading,
            fileHandleForWriting: guestOutput.fileHandleForWriting
        )
        config.serialPorts = [serial]

        let output = guestOutput.fileHandleForReading
        output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            self?.onSerial(text)
        }
        return config
    }

    public static func chooseMemory() -> UInt64 {
        let minimum = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let maximum = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        let physical = ProcessInfo.processInfo.physicalMemory
        var desired = min(UInt64(8) * 1024 * 1024 * 1024, max(physical / 2, minimum))
        desired = min(max(desired, minimum), maximum)
        let megabyte: UInt64 = 1024 * 1024
        return max(minimum, (desired / megabyte) * megabyte)
    }

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        onStopped(nil)
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        onStopped(error.localizedDescription)
    }

    private func loadOrCreateIdentifier() throws -> VZGenericMachineIdentifier {
        try FileManager.default.createDirectory(at: machineDirectory, withIntermediateDirectories: true)
        let url = machineDirectory.appendingPathComponent("id")
        if let data = try? Data(contentsOf: url), let existing = VZGenericMachineIdentifier(dataRepresentation: data) {
            return existing
        }
        let created = VZGenericMachineIdentifier()
        try created.dataRepresentation.write(to: url, options: .atomic)
        return created
    }
}

final class SocketBridge: NSObject, VZVirtioSocketListenerDelegate {
    private let handler: (VZVirtioSocketConnection) -> Void

    init(handler: @escaping (VZVirtioSocketConnection) -> Void) {
        self.handler = handler
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        handler(connection)
        return true
    }
}
