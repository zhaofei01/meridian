import Foundation
import MeridianCore
import MeridianVM

enum SessionError: LocalizedError {
    case unsupported
    case missingImage
    case missingProject
    case bootTimeout

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "这台 Mac 不能启动虚拟机。"
        case .missingImage:
            return "沙箱系统还没准备好。"
        case .missingProject:
            return "这个项目已经不在列表里。"
        case .bootTimeout:
            return "沙箱太久没有准备好。可以看下面的启动记录。"
        }
    }
}

@MainActor
final class SandboxSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case running
        case stopping
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var blocked: [BlockedFile] = []
    @Published var serialLog = ""
    @Published var shellRunning = false
    @Published var workspaceMounted = false
    @Published var statusLine = "沙箱还没有打开"
    @Published var toolNote = ""

    let projectID: UUID
    private let model: AppModel
    private var vm: LinuxVM?
    private var channel: GuestChannel?
    private var mirror: WorkspaceMirror?
    private var anthropic: ModelGateway?
    private var openai: ModelGateway?
    private var github: GitHubGateway?
    private var terminalFeed: ((Data) -> Void)?
    private var cols = 100
    private var rows = 32
    private var sessionAllows: Set<String> = []
    private var readyContinuation: CheckedContinuation<StreamOpen, Error>?
    private var readySettled = false
    private var timeoutTask: Task<Void, Never>?

    init(projectID: UUID, model: AppModel) {
        self.projectID = projectID
        self.model = model
    }

    func attachTerminal(_ feed: @escaping (Data) -> Void) {
        terminalFeed = feed
    }

    func updateSize(cols: Int, rows: Int) {
        self.cols = max(cols, 20)
        self.rows = max(rows, 5)
        channel?.resize(cols: self.cols, rows: self.rows)
    }

    func send(_ data: Data) {
        channel?.sendInput(data)
    }

    func start() {
        guard phase == .idle || phase.isFailed else { return }
        Task { await self.boot() }
    }

    func stop() {
        guard phase == .starting || phase == .running else { return }
        phase = .stopping
        timeoutTask?.cancel()
        finishReady(.failure(SessionError.bootTimeout))
        let channel = self.channel
        let vm = self.vm
        let mirror = self.mirror
        self.channel = nil
        Task {
            channel?.close()
            await vm?.stop()
            mirror?.stop()
            self.phase = .idle
            self.shellRunning = false
            self.statusLine = "沙箱已关闭"
        }
    }

    func launch(_ tool: AgentTool) {
        guard phase == .running else { return }
        let argv: [String]
        switch tool {
        case .claude: argv = ["claude"]
        case .codex: argv = ["codex"]
        case .shell: argv = ["bash"]
        }
        shellRunning = true
        toolNote = ""
        terminalFeed?(Data([0x1b, 0x5b, 0x32, 0x4a, 0x1b, 0x5b, 0x48]))
        channel?.openShell(argv: argv, cwd: "/workspace", cols: cols, rows: rows)
    }

    private func boot() async {
        guard let project = model.projects.first(where: { $0.id == projectID }) else {
            phase = .failed(SessionError.missingProject.localizedDescription)
            return
        }
        guard LinuxVM.isSupported else {
            phase = .failed(SessionError.unsupported.localizedDescription)
            return
        }
        guard let image = GuestImageStore.load() else {
            phase = .failed(SessionError.missingImage.localizedDescription)
            return
        }
        phase = .starting
        statusLine = "正在打开沙箱"
        serialLog = ""
        readySettled = false
        do {
            let mirrorURL = MeridianPaths.mirror(for: projectID)
            let mirror = WorkspaceMirror(project: URL(fileURLWithPath: project.path), mirror: mirrorURL)
            mirror.onChange = { [weak self] blocked in
                Task { @MainActor in self?.blocked = blocked }
            }
            try mirror.rebuild()
            blocked = mirror.blocked
            mirror.startWatching()
            self.mirror = mirror
            let names = blocked.map { "\($0.path)（\($0.reason.rawValue)）" }
            if names.isEmpty {
                model.note(projectID: projectID, level: .info, message: "这个项目没有发现要留在外面的敏感文件。")
            } else {
                model.note(projectID: projectID, level: .deny, message: "留在外面：\(names.joined(separator: "、"))")
            }
            installGateways(gitHub: project.gitHubEnabled)
            let vm = LinuxVM(
                projectID: projectID,
                kernel: image.kernel,
                initramfs: image.initramfs,
                mirrorURL: mirrorURL,
                machineDirectory: MeridianPaths.machine(for: projectID)
            )
            vm.onSerial = { [weak self] text in
                Task { @MainActor in
                    guard let self else { return }
                    self.serialLog.append(text)
                    if self.serialLog.count > 24000 {
                        self.serialLog.removeFirst(self.serialLog.count - 24000)
                    }
                }
            }
            vm.onStopped = { [weak self] message in
                Task { @MainActor in
                    guard let self, self.phase == .running || self.phase == .starting else { return }
                    self.phase = .failed(message ?? "沙箱停了。")
                    self.shellRunning = false
                }
            }
            let channel = GuestChannel()
            vm.onAccept = { connection in
                channel.accept(connection)
            }
            channel.onReady = { [weak self] open in
                Task { @MainActor in
                    guard let self else { return }
                    self.workspaceMounted = open.workspace == true
                    if open.ready == true {
                        self.finishReady(.success(open))
                    } else {
                        let enabled = self.model.projects.first(where: { $0.id == self.projectID })?.gitHubEnabled ?? false
                        self.channel?.sendHello(github: enabled)
                    }
                }
            }
            channel.onShellOutput = { [weak self] data in
                Task { @MainActor in self?.terminalFeed?(data) }
            }
            channel.onShellClose = { [weak self] info in
                Task { @MainActor in
                    self?.shellRunning = false
                    if let error = info?.error, !error.isEmpty {
                        self?.toolNote = error
                    }
                }
            }
            channel.onService = { [weak self] open, reader, writer, close in
                Task { @MainActor in
                    self?.route(open, reader: reader, writer: writer, close: close)
                }
            }
            channel.onTCP = { [weak self] host, port, reader, writer, close, accept in
                Task { @MainActor in
                    await self?.handleTCP(host: host, port: port, reader: reader, writer: writer, close: close, accept: accept)
                }
            }
            self.channel = channel
            self.vm = vm
            let hello: StreamOpen = try await withCheckedThrowingContinuation { continuation in
                self.readyContinuation = continuation
                self.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 180_000_000_000)
                    await MainActor.run {
                        self?.finishReady(.failure(SessionError.bootTimeout))
                    }
                }
                Task {
                    do {
                        try await vm.start()
                    } catch {
                        await MainActor.run {
                            self.finishReady(.failure(error))
                        }
                    }
                }
            }
            timeoutTask?.cancel()
            workspaceMounted = hello.workspace == true
            phase = .running
            statusLine = workspaceMounted ? "沙箱内没有密钥" : "沙箱已打开，项目目录没有挂上"
            var tools: [String] = []
            if image.manifest.hasClaude { tools.append("Claude Code") }
            if image.manifest.hasCodex { tools.append("Codex") }
            toolNote = tools.isEmpty ? "这间沙箱里目前有终端。重新准备系统后可以带上 Claude Code 和 Codex。" : "可以打开 \(tools.joined(separator: "、"))。"
            model.note(projectID: projectID, level: .allow, message: statusLine)
        } catch {
            timeoutTask?.cancel()
            phase = .failed(explain(error))
            statusLine = explain(error)
            model.note(projectID: projectID, level: .deny, message: statusLine)
            channel?.close()
            await vm?.stop()
        }
    }

    private func finishReady(_ result: Result<StreamOpen, Error>) {
        guard !readySettled, let continuation = readyContinuation else { return }
        readySettled = true
        readyContinuation = nil
        timeoutTask?.cancel()
        continuation.resume(with: result)
    }

    private func installGateways(gitHub: Bool) {
        let secrets = model.secrets
        let projectID = projectID
        anthropic = ModelGateway(provider: .anthropic, secret: {
            try? secrets.load(account: ModelProvider.anthropic.keychainAccount)
        }, log: { [weak self] message in
            Task { @MainActor in self?.model.note(projectID: projectID, level: .allow, message: message) }
        })
        openai = ModelGateway(provider: .openai, secret: {
            try? secrets.load(account: ModelProvider.openai.keychainAccount)
        }, log: { [weak self] message in
            Task { @MainActor in self?.model.note(projectID: projectID, level: .allow, message: message) }
        })
        github = GitHubGateway(token: {
            try? secrets.load(account: "github")
        }, authorize: { [weak self] detail in
            guard let self else { return false }
            return await self.model.ask(projectID: projectID, title: "使用 GitHub", detail: detail)
        }, log: { [weak self] message in
            Task { @MainActor in self?.model.note(projectID: projectID, level: .allow, message: message) }
        })
        _ = gitHub
    }

    private func route(_ open: StreamOpen, reader: BufferReader, writer: @escaping (Data) -> Void, close: @escaping () -> Void) {
        let enabled = model.projects.first(where: { $0.id == projectID })?.gitHubEnabled ?? false
        switch open.name {
        case "anthropic":
            anthropic?.serve(reader: reader, writer: writer, close: close)
        case "openai":
            openai?.serve(reader: reader, writer: writer, close: close)
        case "github-mcp":
            guard enabled else {
                writer(HTTPCodec.response(status: 403, reason: "Forbidden", body: Data("GitHub 工具没有打开。".utf8)))
                close()
                return
            }
            github?.serveMCP(reader: reader, writer: writer, close: close)
        case "github-git":
            guard enabled else {
                writer(HTTPCodec.response(status: 403, reason: "Forbidden", body: Data("GitHub 工具没有打开。".utf8)))
                close()
                return
            }
            github?.serveGit(reader: reader, writer: writer, close: close)
        default:
            close()
        }
    }

    private func handleTCP(
        host: String,
        port: Int,
        reader: BufferReader,
        writer: @escaping (Data) -> Void,
        close: @escaping () -> Void,
        accept: @escaping () -> Void
    ) async {
        guard var project = model.projects.first(where: { $0.id == projectID }) else {
            close()
            return
        }
        let policy = NetworkPolicy(
            allowedHosts: Set(project.allowedHosts),
            sessionHosts: sessionAllows,
            gitHubEnabled: project.gitHubEnabled
        )
        let decision = policy.decide(host: host, port: port)
        switch decision {
        case .deny(let message):
            model.note(projectID: projectID, level: .deny, message: message)
            close()
        case .allow:
            guard HostSafety.resolvesToPublicInternet(host) else {
                model.note(projectID: projectID, level: .deny, message: "拒绝联系 \(host)。地址落在内部网络。")
                close()
                return
            }
            model.note(projectID: projectID, level: .allow, message: "允许联系 \(host)。")
            accept()
            TCPBridge.run(host: host, port: port, reader: reader, writer: writer, close: close)
        case .ask(let message):
            let choice = await model.askChoice(projectID: projectID, title: "联系外面", detail: message)
            guard choice != .deny else {
                model.note(projectID: projectID, level: .deny, message: "拒绝联系 \(host)。")
                close()
                return
            }
            if choice == .session {
                sessionAllows.insert(HostSafety.normalize(host))
            }
            if choice == .always {
                model.allowHost(projectID: projectID, host: host)
                project.allowedHosts.append(HostSafety.normalize(host))
            }
            guard HostSafety.resolvesToPublicInternet(host) else {
                model.note(projectID: projectID, level: .deny, message: "拒绝联系 \(host)。地址落在内部网络。")
                close()
                return
            }
            model.note(projectID: projectID, level: .allow, message: "允许联系 \(host)。")
            accept()
            TCPBridge.run(host: host, port: port, reader: reader, writer: writer, close: close)
        }
    }

    private func explain(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("entitlement") || text.contains("virtualization") {
            return "这个应用还没有虚拟化权限。请打开打包后的 Meridian，不要直接运行未签名的程序。"
        }
        return text
    }
}

enum AgentTool {
    case claude
    case codex
    case shell
}

private extension SandboxSession.Phase {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
