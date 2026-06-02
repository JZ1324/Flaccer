import AppKit
import SwiftUI

@main
struct FlaccerApp: App {
    @StateObject private var viewModel = FileScanViewModel()

    var body: some Scene {
        WindowGroup("Flaccer") {
            ContentView(viewModel: viewModel)
                .preferredColorScheme(.dark)
                .frame(minWidth: 900, idealWidth: 960, minHeight: 560, idealHeight: 610)
                .background(WindowChromeConfigurator())
        }
        .defaultSize(width: 960, height: 610)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Files or Folders...") {
                    viewModel.showOpenPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Export Results...") {
                    viewModel.exportCSV()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(viewModel.results.isEmpty)
            }

            CommandMenu("Navigation") {
                Button("Previous Result") {
                    viewModel.selectPreviousResult()
                }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(viewModel.filteredResults.isEmpty)

                Button("Next Result") {
                    viewModel.selectNextResult()
                }
                .keyboardShortcut("]", modifiers: [.command])
                .disabled(viewModel.filteredResults.isEmpty)
            }
        }

        Settings {
            SettingsView(viewModel: viewModel)
                .preferredColorScheme(.dark)
        }
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureWhenReady(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWhenReady(nsView, coordinator: context.coordinator)
    }

    private func configureWhenReady(_ view: NSView, coordinator: Coordinator) {
        let coordinator = coordinator
        DispatchQueue.main.async {
            guard let window = view.window, coordinator.configuredWindow !== window else {
                return
            }
            coordinator.configuredWindow = window

            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isRestorable = false
            window.minSize = CGSize(width: 900, height: 560)
            window.setContentSize(CGSize(width: 960, height: 610))
            window.center()

            coordinator.installHoverControls(in: window)
        }
    }

    final class Coordinator: NSObject {
        weak var configuredWindow: NSWindow?
        private weak var trackerView: WindowControlsTrackerView?
        private var localMouseMonitor: Any?
        private var buttonsVisible: Bool?

        deinit {
            if let localMouseMonitor {
                NSEvent.removeMonitor(localMouseMonitor)
            }
        }

        func installHoverControls(in window: NSWindow) {
            window.acceptsMouseMovedEvents = true
            setWindowButtons(in: window, visible: false, force: true)

            guard trackerView == nil, let contentView = window.contentView else {
                return
            }

            let trackerView = WindowControlsTrackerView(window: window, coordinator: self)
            trackerView.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(trackerView)
            NSLayoutConstraint.activate([
                trackerView.topAnchor.constraint(equalTo: contentView.topAnchor),
                trackerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                trackerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                trackerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
            self.trackerView = trackerView

            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .mouseEntered, .mouseExited]) { [weak self, weak window] event in
                guard let self, let window else {
                    return event
                }

                if event.window === window {
                    self.updateWindowButtons(for: event, in: window)
                } else {
                    self.hideWindowButtons(in: window)
                }
                return event
            }
        }

        func showWindowButtons(in window: NSWindow) {
            setWindowButtons(in: window, visible: true)
        }

        func hideWindowButtons(in window: NSWindow) {
            setWindowButtons(in: window, visible: false)
        }

        func updateWindowButtons(for event: NSEvent, in window: NSWindow) {
            guard let contentView = window.contentView else {
                return
            }

            let point = contentView.convert(event.locationInWindow, from: nil)
            let topZoneY = contentView.isFlipped ? 0 : max(contentView.bounds.height - 74, 0)
            let hoverZone = CGRect(x: 0, y: topZoneY, width: 160, height: 74)
            setWindowButtons(in: window, visible: hoverZone.contains(point))
        }

        private func setWindowButtons(in window: NSWindow, visible: Bool, force: Bool = false) {
            guard force || buttonsVisible != visible else {
                return
            }
            buttonsVisible = visible

            [
                NSWindow.ButtonType.closeButton,
                .miniaturizeButton,
                .zoomButton,
                .toolbarButton
            ].compactMap { window.standardWindowButton($0) }
                .forEach { button in
                    button.isHidden = false
                    button.isEnabled = visible
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = visible ? 0.10 : 0.16
                        button.animator().alphaValue = visible ? 1 : 0
                    }
                }
        }
    }
}

private final class WindowControlsTrackerView: NSView {
    private weak var trackedWindow: NSWindow?
    private weak var coordinator: WindowChromeConfigurator.Coordinator?
    private var trackingArea: NSTrackingArea?

    init(window: NSWindow, coordinator: WindowChromeConfigurator.Coordinator) {
        self.trackedWindow = window
        self.coordinator = coordinator
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        guard let trackedWindow else {
            return
        }
        coordinator?.updateWindowButtons(for: event, in: trackedWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let trackedWindow else {
            return
        }
        coordinator?.updateWindowButtons(for: event, in: trackedWindow)
    }

    override func mouseExited(with event: NSEvent) {
        guard let trackedWindow else {
            return
        }
        coordinator?.hideWindowButtons(in: trackedWindow)
    }
}
