import SwiftUI

// A consistent centered toolbar title. Reserves horizontal padding so the glass
// pill the toolbar draws around it never hugs the text, and a stable width so it
// doesn't jitter when the title changes.
struct ToolbarTitleLabel: View {
    let text: String
    var minWidth: CGFloat = 0

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(minWidth: minWidth)
    }
}
