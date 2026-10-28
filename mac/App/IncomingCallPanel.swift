import AppKit
import AMProtocol
import FeatureCalls
import SwiftUI

/// A floating panel that never takes keyboard focus from the user's current app.
private final class CallPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Keeps one panel per ringing call at the top right of the main screen, stacked when there are several.
@MainActor
final class IncomingCallPanels {
    private let model: CallModel
    private var panels: [String: NSPanel] = [:]
    private static let gap: CGFloat = 8

    init(model: CallModel) {
        self.model = model
        sync()
    }

    private func sync() {
        let ringing = withObservationTracking { model.ringing } onChange: { [weak self] in
            Task { @MainActor in self?.sync() }
        }
        let ids = Set(ringing.map(\.callID))
        for (id, panel) in panels where !ids.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
        for call in ringing where panels[call.callID] == nil {
            panels[call.callID] = makePanel(callID: call.callID)
        }
        layout(order: ringing.map(\.callID))
    }

    private func makePanel(callID: String) -> NSPanel {
        let panel = CallPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 110),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: IncomingCallView(model: model, callID: callID))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        return panel
    }

    /// Newest at the bottom of the stack, so the oldest sits nearest the corner.
    private func layout(order: [String]) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        var top = area.maxY - Self.gap
        for id in order {
            guard let panel = panels[id] else { continue }
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - Self.gap, y: top - size.height))
            panel.orderFrontRegardless()
            top -= size.height + Self.gap
        }
    }
}

private struct IncomingCallView: View {
    let model: CallModel
    let callID: String

    var body: some View {
        if let call = model.ringing.first(where: { $0.callID == callID }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.displayName(call)).font(.headline).lineLimit(1)
                if !call.number.isEmpty, model.displayName(call) != call.number {
                    Text(call.number).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack {
                    ForEach(model.actions(for: call), id: \.self) { action in
                        button(action)
                    }
                }
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Incoming call from \(model.displayName(call))"))
        }
    }

    @ViewBuilder private func button(_ action: CallPanelAction) -> some View {
        switch action {
        case .answer:
            Button { Task { await model.answer(callID) } } label: { Text("Answer") }
                .buttonStyle(.borderedProminent).tint(.green)
                .accessibilityLabel(Text("Answer"))
        case .decline:
            Button { Task { await model.decline(callID) } } label: { Text("Decline") }
                .buttonStyle(.borderedProminent).tint(.red)
                .accessibilityLabel(Text("Decline"))
        case .close:
            Button { model.close(callID) } label: { Text("Close") }
                .accessibilityLabel(Text("Close"))
        }
    }
}
