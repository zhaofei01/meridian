import MeridianCore
import SwiftUI

struct AccountSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var anthropic = ""
    @State private var openai = ""
    @State private var github = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                MeridianMark().frame(width: 22, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("连接账号")
                        .font(.system(size: 22, weight: .medium, design: .serif))
                    Text("钥匙只放在这台电脑的钥匙串里，不会写进沙箱。")
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            accountRow(title: "Anthropic", connected: model.anthropicConnected, text: $anthropic, account: ModelProvider.anthropic.keychainAccount)
            accountRow(title: "OpenAI", connected: model.openaiConnected, text: $openai, account: ModelProvider.openai.keychainAccount)
            accountRow(title: "GitHub", connected: model.githubConnected, text: $github, account: "github")
            if let accountError = model.accountError {
                Text(accountError).foregroundStyle(Theme.line)
            }
            Text("GitHub 可以填个人访问令牌。沙箱里的程序以后只用一个内部地址，拿不到这把令牌。")
                .font(.callout)
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 560, height: 460)
        .background(Theme.paper)
    }

    private func accountRow(title: String, connected: Bool, text: Binding<String>, account: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Text(connected ? "已连接" : "未连接")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(connected ? Theme.good.opacity(0.15) : Color.black.opacity(0.05))
                    .foregroundStyle(connected ? Theme.good : Theme.muted)
                    .clipShape(Capsule())
                Spacer()
                if connected {
                    Button("断开") { model.disconnect(account) }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                SecureField("在这里填入，只留在这台电脑上", text: text)
                    .textFieldStyle(.roundedBorder)
                Button("连接") {
                    model.connect(account, secret: text.wrappedValue)
                    text.wrappedValue = ""
                }
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
