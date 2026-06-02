import SwiftUI

struct VerdictBadge: View {
    let verdict: SpectrumVerdict

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)

            Text(verdict.rawValue)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .monospaced()
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color.black, in: Capsule(style: .continuous))
    }

    private var dotColor: Color {
        switch verdict {
        case .lossless:
            return Color(red: 0.12, green: 0.84, blue: 0.32)
        case .medium:
            return .yellow
        case .fake:
            return .red
        case .error:
            return .gray
        case .all:
            return .blue
        }
    }
}
