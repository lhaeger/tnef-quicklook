import SwiftUI

@main
struct TNEFPreviewApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("TNEF Preview").font(.title)
                Text("The Quick Look extension for winmail.dat is installed.")
                Text("Select a winmail.dat attachment in Mail or Finder and press the spacebar.")
                Text("If nothing happens, check System Settings → General → Login Items & Extensions → Quick Look.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(minWidth: 460)
        }
        .windowResizability(.contentSize)
    }
}
