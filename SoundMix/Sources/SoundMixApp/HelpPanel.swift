import SwiftUI

struct HelpPanel: View {
    @State private var helpContent: String = "Loading..."
    
    var body: some View {
        CZCard(title: "Help & Documentation", subtitle: "Learn how to configure and use SoundMix.") {
            ScrollView {
                Text(helpContent)
                    .font(CZ.Typography.body(14, .regular))
                    .foregroundStyle(CZ.Color.darkBlue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(CZ.Color.white)
            .clipShape(RoundedRectangle(cornerRadius: CZ.Radius.medium))
        }
        .onAppear {
            loadHelpContent()
        }
    }
    
    private func loadHelpContent() {
        if let url = Bundle.main.url(forResource: "Help", withExtension: "md"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            helpContent = content
        } else {
            helpContent = "Help documentation could not be loaded. Please ensure Help.md is included in the application bundle."
        }
    }
}
