import Foundation
import MeridianCore
import MeridianVM
import SwiftUI

enum ApprovalChoice: Equatable {
    case once
    case session
    case always
    case deny
}

struct PendingApproval: Identifiable, Equatable {
    var id = UUID()
    var projectID: UUID
    var title: String
    var detail: String
}

enum ImagePhase: Equatable {
    case missing
    case ready(GuestImageManifest)
    case building
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var projects: [ProjectRecord] = []
    @Published var selectedProjectID: UUID?
    @Published var events: [ActivityEvent] = []
    @Published var anthropicConnected = false
    @Published var openaiConnected = false
    @Published var githubConnected = false
    @Published var showingAccounts = false
    @Published var pending: PendingApproval?
    @Published var imagePhase: ImagePhase = .missing
    @Published var imageLog = ""
    @Published var accountError: String?

    let secrets: KeychainSecretStore
    private let store: ProjectStore
    private let activity: ActivityLog
    private var sessions: [UUID: SandboxSession] = [:]
    private var approvalQueue: [PendingApproval] = []
    private var approvalWaiters: [UUID: CheckedContinuation<ApprovalChoice, Never>] = [:]
    private var imageProcess: Process?

    init() {
        let secrets = KeychainSecretStore()
        self.secrets = secrets
        store = ProjectStore()
        activity = ActivityLog()
        try? MeridianPaths.ensure()
        projects = (try? store.load()) ?? []
        events = activity.events
        refreshAccounts()
        refreshImage()
    }

    func refreshAccounts() {
        anthropicConnected = (try? secrets.load(account: ModelProvider.anthropic.keychainAccount)) != nil
        openaiConnected = (try? secrets.load(account: ModelProvider.openai.keychainAccount)) != nil
        githubConnected = (try? secrets.load(account: "github")) != nil
    }

    func refreshImage() {
        if case .building = imagePhase { return }
        if let image = GuestImageStore.load() {
            imagePhase = .ready(image.manifest)
        } else {
            imagePhase = .missing
        }
    }

    func connect(_ account: String, secret: String) {
        do {
            try secrets.save(account: account, secret: secret)
            accountError = nil
            refreshAccounts()
            note(projectID: nil, level: .info, message: "已在这台电脑上连接账号。钥匙留在钥匙串里。")
        } catch SecretStoreError.rejected {
            accountError = "这不是一把可用的钥匙。"
        } catch {
            accountError = "没有写进钥匙串。"
        }
    }

    func disconnect(_ account: String) {
        try? secrets.delete(account: account)
        refreshAccounts()
    }

    func addProject(at url: URL) {
        let path = url.standardizedFileURL.path
        if let existing = projects.first(where: { $0.path == path }) {
            selectedProjectID = existing.id
            return
        }
        var record = ProjectRecord(name: url.lastPathComponent, path: path)
        if record.name.isEmpty { record.name = "未命名项目" }
        projects.append(record)
        selectedProjectID = record.id
        persist()
        note(projectID: record.id, level: .info, message: "选了项目 \(record.name)。")
    }

    func removeProject(_ id: UUID) {
        sessions[id]?.stop()
        sessions[id] = nil
        projects.removeAll { $0.id == id }
        if selectedProjectID == id { selectedProjectID = projects.first?.id }
        persist()
    }

    func update(_ project: ProjectRecord) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index] = project
        persist()
    }

    func allowHost(projectID: UUID, host: String) {
        guard var project = projects.first(where: { $0.id == projectID }) else { return }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !project.allowedHosts.contains(host) {
            project.allowedHosts.append(host)
            update(project)
        }
    }

    func allowGitHubRepo(projectID: UUID, repo: String) {
        guard var project = projects.first(where: { $0.id == projectID }) else { return }
        if !project.allowedGitHubRepos.contains(repo) {
            project.allowedGitHubRepos.append(repo)
            update(project)
        }
    }

    func session(for id: UUID) -> SandboxSession {
        if let existing = sessions[id] { return existing }
        let session = SandboxSession(projectID: id, model: self)
        sessions[id] = session
        return session
    }

    func stopAll() {
        for session in sessions.values {
            session.stop()
        }
    }

    func ask(projectID: UUID, title: String, detail: String) async -> Bool {
        let choice = await askChoice(projectID: projectID, title: title, detail: detail)
        return choice != .deny
    }

    func askChoice(projectID: UUID, title: String, detail: String) async -> ApprovalChoice {
        await withCheckedContinuation { continuation in
            let item = PendingApproval(projectID: projectID, title: title, detail: detail)
            approvalQueue.append(item)
            approvalWaiters[item.id] = continuation
            pending = approvalQueue.first
        }
    }

    func decide(_ choice: ApprovalChoice) {
        guard let head = approvalQueue.first else { return }
        approvalQueue.removeFirst()
        approvalWaiters.removeValue(forKey: head.id)?.resume(returning: choice)
        pending = approvalQueue.first
    }

    func note(projectID: UUID?, level: ActivityEvent.Level, message: String) {
        let loaded = ["anthropic", "openai", "github"].compactMap { try? self.secrets.load(account: $0) }
        let event = activity.append(projectID: projectID, level: level, message: message, secrets: loaded)
        events = activity.events
        _ = event
    }

    func prepareImage() {
        guard imageProcess == nil else { return }
        guard let script = ToolPaths.resource("build-guest-image.py"),
              let agent = ToolPaths.resource("meridian-agent.py"),
              let initScript = ToolPaths.resource("guest-init.sh") else {
            imagePhase = .failed("找不到准备沙箱系统的脚本。")
            return
        }
        imagePhase = .building
        imageLog = ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            script.path,
            "--output", MeridianPaths.guestImage.path,
            "--agent", agent.path,
            "--init", initScript.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self.imageLog.append(text)
                if self.imageLog.count > 40000 {
                    self.imageLog.removeFirst(self.imageLog.count - 40000)
                }
            }
        }
        process.terminationHandler = { process in
            Task { @MainActor in
                self.imageProcess = nil
                pipe.fileHandleForReading.readabilityHandler = nil
                if process.terminationStatus == 0, let image = GuestImageStore.load() {
                    self.imagePhase = .ready(image.manifest)
                    self.note(projectID: nil, level: .info, message: "沙箱系统已准备好。")
                } else {
                    self.imagePhase = .failed("沙箱系统没有准备好。")
                }
            }
        }
        do {
            try MeridianPaths.ensure()
            try process.run()
            imageProcess = process
        } catch {
            imagePhase = .failed("没有开始准备沙箱系统。")
        }
    }

    private func persist() {
        try? store.save(projects)
    }
}
