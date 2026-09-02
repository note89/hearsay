import SwiftUI

struct OverlayView: View {
    let model: OverlayModel

    private static let pillHeight: CGFloat = 46

    /// Good news steps back; everything else needs to be read.
    private var pillOpacity: Double {
        if case .settled(_, .ok) = model.state { return 0.62 }
        return 0.86
    }

    var body: some View {
        HStack(spacing: 12) {
            switch model.state {
            case .hidden:
                EmptyView()
            case .listening(let partial):
                if let badge = model.badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(Color.orange.opacity(0.6), lineWidth: 1))
                }
                Waveform(levels: model.levels)
                Text(partial.isEmpty ? "listening…" : partial)
                    .foregroundStyle(partial.isEmpty ? Color.white.opacity(0.55) : Color.white)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .working(let label):
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text(label)
                    .foregroundStyle(.white.opacity(0.8))
            case .settled(let message, let tone):
                Image(systemName: tone == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(tone == .ok ? Color.green : Color.orange)
                Text(message)
                    .foregroundStyle(.white.opacity(tone == .ok ? 0.85 : 1))
                    .lineLimit(1)
            }
        }
        .font(.system(size: 13, weight: .medium, design: .rounded))
        .padding(.horizontal, 18)
        .frame(height: Self.pillHeight)
        .frame(maxWidth: OverlayPanel.size.width - 24)
        .background(Capsule().fill(Color.black.opacity(pillOpacity)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .frame(width: OverlayPanel.size.width, height: OverlayPanel.size.height)
    }
}

private struct Waveform: View {
    let levels: [Float]

    private static let barHeight: CGFloat = 22

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: max(3, CGFloat(levels[index]) * Self.barHeight))
            }
        }
        .frame(height: Self.barHeight)
        .animation(.linear(duration: 0.04), value: levels)
    }
}
