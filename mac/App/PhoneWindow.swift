import SwiftUI

/// The "Phone" window: one tab per thing done with the phone. Photos and Files join Send later.
struct PhoneWindow: View {
    let model: AppModel

    var body: some View {
        TabView {
            SendTab(model: model)
                .tabItem { Text("Send") }
        }
        .padding()
        .frame(minWidth: 440, minHeight: 380)
    }
}
