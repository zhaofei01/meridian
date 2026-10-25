import AppKit
import MeridianCore
import MeridianVM
import SwiftUI

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    MeridianMark().frame(width: 16, height: 28)
                    Text("项目")
                        .font(.system(size: 18, weight: .medium, design: .serif))
                    Spacer()
                    Button {
                        chooseFolder()
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .help("选择项目文件夹")
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
                List(selection: $model.selectedProjectID) {
                    ForEach(model.projects) { project in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name).foregroundStyle(Theme.ink)
                            Text(project.path)
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                        }
                        .tag(project.id)
                        .contextMenu {
                            Button("从列表移除") { model.removeProject(project.id) }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let id = model.selectedProjectID, let project = model.projects.first(where: { $0.id == id }) {
                ProjectDetail(project: project)
            } else {
                Welcome()
            }
        }
        .background(Theme.paper)
        .toolbar {
            ToolbarItem {
                Button("连接账号") { model.showingAccounts = true }
            }
        }
        .sheet(isPresented: $model.showingAccounts) {
            AccountSheet().environmentObject(model)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "Agent 只能看到这个文件夹。钥匙和其他文件夹留在外面。"
        if panel.runModal() == .OK, let url = panel.url {
            model.addProject(at: url)
        }
    }
}

private struct Welcome: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 16) {
                    MeridianMark().frame(width: 28, height: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Meridian")
                            .font(.system(size: 36, weight: .medium, design: .serif))
                        Text("给 Agent 一间带锁的工作室")
                            .foregroundStyle(Theme.muted)
                    }
                }
                Text("Claude Code、Codex 在沙箱里改你选中的项目。API Key、GitHub 令牌和电脑上的其他文件留在外面。沙箱里没有可以偷走的钥匙。")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    step("1", "连接账号", "在这台电脑上完成，不进沙箱")
                    step("2", "选择项目", "只挂这一个文件夹")
                    step("3", "打开沙箱", "在里面运行 Agent")
                }
                accountLine
                imageLine
                if let pending = model.pending {
                    ApprovalCard(pending: pending)
                }
            }
            .padding(36)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.paper)
    }

    private var accountLine: some View {
        HStack(spacing: 16) {
            label("Anthropic", model.anthropicConnected)
            label("OpenAI", model.openaiConnected)
            label("GitHub", model.githubConnected)
            Spacer()
            Button("连接账号") { model.showingAccounts = true }
                .buttonStyle(.borderedProminent)
                .tint(Theme.line)
        }
    }

    private var imageLine: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.imagePhase {
            case .missing:
                Text("还没有准备沙箱里的系统。准备一次之后，每个项目都能用。")
                Button("准备沙箱系统") { model.prepareImage() }
                    .buttonStyle(.bordered)
            case .building:
                Text("正在准备沙箱系统，第一次会下载 Linux 和工具。")
                log
            case .failed(let message):
                Text(message).foregroundStyle(Theme.line)
                log
                Button("再试一次") { model.prepareImage() }
            case .ready(let manifest):
                Text(readyText(manifest)).foregroundStyle(Theme.good)
            }
        }
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var log: some View {
        ScrollView {
            Text(model.imageLog.isEmpty ? "…" : model.imageLog)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 120)
    }

    private func readyText(_ manifest: GuestImageManifest) -> String {
        var tools = ["终端"]
        if manifest.hasClaude { tools.append("Claude Code") }
        if manifest.hasCodex { tools.append("Codex") }
        return "沙箱系统已准备好，里面有\(tools.joined(separator: "、"))。"
    }

    private func label(_ name: String, _ on: Bool) -> some View {
        Text("\(name) \(on ? "已连接" : "未连接")")
            .font(.callout)
            .foregroundStyle(on ? Theme.good : Theme.muted)
    }

    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(number)
                .font(.system(size: 13, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.line)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct ProjectDetail: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let project: ProjectRecord
    @State private var blocked: [BlockedFile] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(project.name)
                    .font(.system(size: 32, weight: .medium, design: .serif))
                Text(project.path)
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
                Toggle("允许使用已连接的 GitHub", isOn: githubBinding)
                    .toggleStyle(.switch)
                Text("打开后，GitHub 的令牌仍留在这台电脑上。沙箱只拿到结果。")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                if blocked.isEmpty {
                    Text("没有发现要拦下的敏感文件。如果项目里有 .env 或私钥，它们不会被送进沙箱。")
                        .font(.callout)
                        .foregroundStyle(Theme.muted)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("这些会留在外面")
                            .font(.headline)
                        ForEach(blocked.prefix(12)) { item in
                            Text("\(item.path) · \(item.reason.rawValue)")
                                .font(.callout)
                        }
                        if blocked.count > 12 {
                            Text("还有 \(blocked.count - 12) 个")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
                HStack {
                    Button("打开沙箱") {
                        openWindow(id: "sandbox", value: project.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.line)
                    Button("从列表移除") { model.removeProject(project.id) }
                }
                if let pending = model.pending, pending.projectID == project.id {
                    ApprovalCard(pending: pending)
                }
                ActivityList(events: model.events.filter { $0.projectID == project.id })
            }
            .padding(36)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.paper)
        .onAppear { blocked = ProjectScan.blockedFiles(in: URL(fileURLWithPath: project.path)) }
    }

    private var githubBinding: Binding<Bool> {
        Binding(
            get: { project.gitHubEnabled },
            set: { value in
                var copy = project
                copy.gitHubEnabled = value
                model.update(copy)
            }
        )
    }
}

struct ApprovalCard: View {
    @EnvironmentObject private var model: AppModel
    let pending: PendingApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pending.title).font(.headline)
            Text(pending.detail)
            HStack {
                Button("允许一次") { model.decide(.once) }
                Button("这次都允许") { model.decide(.session) }
                Button("一直允许") { model.decide(.always) }
                Button("拒绝") { model.decide(.deny) }
            }
        }
        .padding(14)
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line.opacity(0.45), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct ActivityList: View {
    let events: [ActivityEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("刚才的往来").font(.headline)
            if events.isEmpty {
                Text("还没有记录。").foregroundStyle(Theme.muted)
            } else {
                ForEach(events.suffix(8).reversed()) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(color(event.level))
                            .frame(width: 7, height: 7)
                        Text(event.message)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func color(_ level: ActivityEvent.Level) -> Color {
        switch level {
        case .info: return Theme.muted
        case .allow: return Theme.good
        case .deny: return Theme.line
        }
    }
}
