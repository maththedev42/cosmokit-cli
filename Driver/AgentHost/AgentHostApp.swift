import SwiftUI

@main
struct AgentHostApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack { List { Text("CosmoKit Agent Host").accessibilityIdentifier("agent.host.ready") }.navigationTitle("Agent Host") }
        }
    }
}
