import SwiftUI

struct SettingsView: View {
    var body: some View {
        List {
            Section("Distribution") {
                LabeledContent("Backend") {
                    Text("Supabase")
                }
                LabeledContent("Sharing") {
                    Text("Native share sheet")
                }
            }

            LinkedInSettingsSection()

            Section("Status") {
                Text("This shell is ready for data wiring.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
