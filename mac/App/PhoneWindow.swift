import SwiftUI

/// The "Phone" window: one tab per thing done with the phone (Send, Notifications, Photos, Files,
/// Now Playing), and
/// "Show Phone Screen" in the toolbar while the phone can show its screen.
/// Closing it drops the photo thumbnails (they live in memory only, while the window is open).
struct PhoneWindow: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.phoneTab) {
            SendTab(model: model)
                .tabItem { Text("Send") }
                .tag(PhoneTab.send)
            NotificationsTab(model: model)
                .tabItem { Text("Notifications") }
                .tag(PhoneTab.notifications)
            PhotosTab(model: model)
                .tabItem { Text("Photos") }
                .tag(PhoneTab.photos)
            FilesTab(model: model)
                .tabItem { Text("Files") }
                .tag(PhoneTab.files)
            NowPlayingTab(model: model)
                .tabItem { Text("Now Playing") }
                .tag(PhoneTab.nowPlaying)
        }
        .padding()
        .frame(minWidth: 560, minHeight: 380)
        .toolbar {
            if model.canMirror {
                ToolbarItem {
                    Button("Show Phone Screen") { model.showMirror() }
                        .accessibilityLabel(Text("Show Phone Screen"))
                }
            }
        }
        .onDisappear { model.photos.clear() }
    }
}
