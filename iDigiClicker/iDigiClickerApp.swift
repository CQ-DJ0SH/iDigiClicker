import SwiftUI
import AppKit

@main
struct iDigiClickerApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 760, minHeight: 680)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About iDigiClicker") {
                    let credits = NSAttributedString(
                        string: "by DJØSH with support from Claude",
                        attributes: [
                            .foregroundColor: NSColor.labelColor,
                            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                        ]
                    )
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .credits: credits
                    ])
                }
            }
        }
    }
}
