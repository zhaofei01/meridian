import MeridianCore
import SwiftUI

struct SandboxRoot: View {
    @EnvironmentObject private var model: AppModel
    let projectID: UUID

    var body: some View {
        SandboxView(session: model.session(for: projectID))
    }
}

struct SandboxView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: SandboxSession

    private var project: ProjectRecord? {
        model.projects.first { $0.id == session.projectID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let pending = model.pending, pending.projectID == session.projectID {
                ApprovalCard(pending: pending)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            HStack(spacing: 0) {
                TerminalPane(session: session)
                    .overlay(alignment: .center) {
                        if !session.shellRunning && session.phase != .running {
                            Text(placeholder)
                                .foregroundStyle(.white.opacity(0.72))
                                .padding(24)
                        }
                    }
                side
                    .frame(width: 280)
            }
        }
        .background(Theme.paper)
        .onDisappear { session.stop() }
        .onChange(of: model.imagePhase) { _, phase in
            if case .ready = phase, session.startWhenImageReady {
                session.startWhenImageReady = false
                session.start()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project?.name ?? "沙箱")
                    .font(.system(size: 20, weight: .medium, design: .serif))
                Text(session.statusLine)
                    .font(.callout)
                    .foregroundStyle(session.phase == .running ? Theme.good : Theme.muted)
            }
            Spacer()
            Button("Claude Code") { session.launch(.claude) }
                .disabled(session.phase != .running || !hasClaude)
                .help(hasClaude ? "在沙箱里打开 Claude Code" : "这套沙箱系统还没有 Claude Code")
            Button("Codex") { session.launch(.codex) }
                .disabled(session.phase != .running || !hasCodex)
                .help(hasCodex ? "在沙箱里打开 Codex" : "这套沙箱系统还没有 Codex")
            Button("终端") { session.launch(.shell) }
                .disabled(session.phase != .running)
            if session.phase == .running || session.phase == .starting {
                Button("关闭沙箱") { session.stop() }
            } else if case .building = model.imagePhase {
                Button("正在准备系统") {}
                    .disabled(true)
            } else {
                Button("打开沙箱") { begin() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.line)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var side: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(session.phase == .running ? "沙箱内没有密钥" : "钥匙留在这台电脑上")
                    .font(.headline)
                Text(session.toolNote)
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                if session.workspaceMounted {
                    Text("项目目录已挂上")
                        .font(.callout)
                        .foregroundStyle(Theme.good)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("留在外面").font(.headline)
                    if session.blocked.isEmpty {
                        Text("没有拦下文件。").font(.callout).foregroundStyle(Theme.muted)
                    } else {
                        ForEach(session.blocked.prefix(10)) { item in
                            Text("\(item.path)")
                                .font(.caption)
                                .lineLimit(2)
                        }
                    }
                }
                ActivityList(events: model.events.filter { $0.projectID == session.projectID })
                if !session.serialLog.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("启动记录").font(.headline)
                        Text(session.serialLog)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                if case .missing = model.imagePhase {
                    Button("准备沙箱系统") { model.prepareImage() }
                } else if case .building = model.imagePhase {
                    Text("正在准备沙箱系统")
                        .font(.callout)
                    Text(model.imageLog)
                        .font(.system(size: 10, design: .monospaced))
                } else if case .failed(let message) = model.imagePhase {
                    Text(message).foregroundStyle(Theme.line)
                    Button("再试一次") { model.prepareImage() }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.paper)
    }

    private var placeholder: String {
        switch session.phase {
        case .idle:
            return "打开沙箱后，在这里运行 Claude Code 或 Codex。"
        case .starting:
            return "正在打开沙箱。"
        case .failed(let message):
            return message
        case .stopping:
            return "正在关闭。"
        case .running:
            return "选择上面的工具。"
        }
    }

    private var hasClaude: Bool {
        if case .ready(let manifest) = model.imagePhase { return manifest.hasClaude }
        return session.hasClaude
    }

    private var hasCodex: Bool {
        if case .ready(let manifest) = model.imagePhase { return manifest.hasCodex }
        return session.hasCodex
    }

    private func begin() {
        if case .ready = model.imagePhase {
            session.start()
            return
        }
        session.startWhenImageReady = true
        if case .building = model.imagePhase { return }
        model.prepareImage()
    }
}
