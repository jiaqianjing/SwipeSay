import SwiftUI

@main
struct SwipeSayApp: App {
    var body: some Scene {
        WindowGroup("SwipeSay") {
            ContentView()
        }
        .defaultSize(width: 560, height: 400)
    }
}

struct ContentView: View {
    var body: some View {
        ContentUnavailableView(
            "SwipeSay",
            systemImage: "highlighter",
            description: Text("Select a line. Understand it in context.")
        )
        .frame(minWidth: 420, minHeight: 300)
        .background(.background)
    }
}
