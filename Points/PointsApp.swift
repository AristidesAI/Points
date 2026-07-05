import SwiftUI

@main
struct PointsApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Browser → main stage, with the first-launch tutorial floating over the stage.
struct RootView: View {
    @State private var showBrowser = true
    @State private var template: String?
    @State private var signals = TutorialSignals()
    @AppStorage("tutorialDone") private var tutorialDone = false

    var body: some View {
        ZStack {
            if showBrowser {
                BrowserView(onOpen: { t in
                    template = t
                    withAnimation(.easeInOut(duration: 0.2)) { showBrowser = false }
                })
            } else {
                ContentView(template: template, signals: signals, onBrowser: {
                    withAnimation(.easeInOut(duration: 0.2)) { showBrowser = true }
                })
                if !tutorialDone {
                    TutorialOverlay(signals: signals, onDone: { tutorialDone = true })
                        .transition(.opacity)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
