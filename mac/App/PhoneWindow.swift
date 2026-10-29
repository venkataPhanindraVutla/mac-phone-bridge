import SwiftUI

/// The "Phone" window: one tab per thing done with the phone. Files joins Send and Photos later.
/// Closing it drops the photo thumbnails (they live in memory only, while the window is open).
struct PhoneWindow: View {
    let model: AppModel

    var body: some View {
        TabView {
            SendTab(model: model)
                .tabItem { Text("Send") }
            PhotosTab(model: model)
                .tabItem { Text("Photos") }
        }
        .padding()
        .frame(minWidth: 440, minHeight: 380)
        .onDisappear { model.photos.clear() }
    }
}
