import SwiftUI

struct HelpPanel: View {
    var body: some View {
        CZCard(title: "Help & Documentation", subtitle: "Learn how to configure and use SoundMix.") {
            VStack(alignment: .leading, spacing: CZ.Spacing.lg) {
                Text("SoundMix includes built-in macOS Help documentation.")
                    .font(CZ.Typography.body(14, .regular))
                    .foregroundStyle(CZ.Color.darkBlue)
                
                CZButton(title: "Open Help Viewer", icon: "book", variant: .primary) {
                    NSWorkspace.shared.open(URL(string: "help:anchor=Help&bookID=io.soundmix.app.help")!)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(CZ.Color.white)
            .clipShape(RoundedRectangle(cornerRadius: CZ.Radius.medium))
        }
    }
}
