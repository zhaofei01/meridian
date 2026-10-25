import SwiftUI

enum Theme {
    static let paper = Color(red: 0.953, green: 0.937, blue: 0.906)
    static let ink = Color(red: 0.122, green: 0.106, blue: 0.094)
    static let muted = Color(red: 0.42, green: 0.38, blue: 0.34)
    static let line = Color(red: 0.545, green: 0.227, blue: 0.165)
    static let card = Color(red: 0.988, green: 0.980, blue: 0.965)
    static let good = Color(red: 0.176, green: 0.396, blue: 0.286)
    static let warn = Color(red: 0.55, green: 0.36, blue: 0.14)
}

struct MeridianMark: View {
    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let width = proxy.size.width
            Path { path in
                path.move(to: CGPoint(x: width / 2, y: 0))
                path.addLine(to: CGPoint(x: width / 2, y: height))
            }
            .stroke(Theme.line, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            Circle()
                .fill(Theme.line)
                .frame(width: min(width, height) * 0.28, height: min(width, height) * 0.28)
                .position(x: width / 2, y: height * 0.42)
        }
    }
}
