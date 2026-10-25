import AppKit
import SwiftTerm
import SwiftUI

struct TerminalPane: NSViewRepresentable {
    @ObservedObject var session: SandboxSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> TerminalView {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = TerminalView(frame: .zero, font: font)
        view.nativeForegroundColor = NSColor(calibratedWhite: 0.93, alpha: 1)
        view.nativeBackgroundColor = NSColor(calibratedRed: 0.11, green: 0.105, blue: 0.095, alpha: 1)
        view.terminalDelegate = context.coordinator
        session.attachTerminal { data in
            let bytes = [UInt8](data)
            DispatchQueue.main.async {
                view.feed(byteArray: bytes[...])
            }
        }
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: SandboxSession

        init(session: SandboxSession) {
            self.session = session
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let payload = Data(data)
            Task { @MainActor in
                session.send(payload)
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in
                session.updateSize(cols: newCols, rows: newRows)
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else { return }
            NSWorkspace.shared.open(url)
        }

        func bell(source: TerminalView) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(content, forType: .string)
        }

        func clipboardRead(source: TerminalView) -> Data? { nil }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
