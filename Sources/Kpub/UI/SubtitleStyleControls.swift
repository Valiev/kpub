import KpubCore
import SwiftUI

/// Ползунки «насколько заметны субтитры» с живым примером.
struct SubtitleStyleControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                LinearGradient(colors: [Color(white: 0.35), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                Text("— Ты уверен, что это хорошая идея?\n— Нет. Но другой у нас нет.")
                    .font(.system(size: 15 * model.subtitleStyle.scale))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(model.subtitleStyle.opacity))
                    .shadow(color: .black.opacity(0.6 * model.subtitleStyle.opacity), radius: 1)
                    .padding(.horizontal, 10)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 10)
            }
            .frame(height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            LabeledContent("Непрозрачность \(Int(model.subtitleStyle.opacity * 100))%") {
                Slider(value: $model.subtitleStyle.opacity, in: SubtitleStyle.opacityRange)
            }
            LabeledContent("Размер \(Int(model.subtitleStyle.scale * 100))%") {
                Slider(value: $model.subtitleStyle.scale, in: SubtitleStyle.scaleRange)
            }
            HStack {
                Button("Как обычно") { model.subtitleStyle = SubtitleStyle() }
                Button("Ненавязчиво") { model.subtitleStyle = SubtitleStyle(opacity: 0.55, scale: 0.9) }
            }
            .controlSize(.small)
        }
    }
}
