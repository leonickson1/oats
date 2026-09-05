import SwiftUI

// A modern, glassy segmented control: a glass capsule with a neutral highlight
// that slides to the selected segment. No system accent (blue) tint.
struct GlassSegmented<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { opt in
                let selected = opt.value == selection
                Button {
                    withAnimation(Motion.standard) { selection = opt.value }
                } label: {
                    Text(opt.label)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .contentShape(Capsule())
                        .background {
                            if selected {
                                Capsule()
                                    .fill(.primary.opacity(0.10))
                                    .matchedGeometryEffect(id: "seg-highlight", in: ns)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
    }
}
