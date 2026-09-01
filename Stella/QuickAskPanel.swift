//
//  QuickAskPanelController.swift
//  Stella
//
//  Created by Harish Maheshwaran on 29/08/26.
//


import AppKit
import SwiftUI

@MainActor
final class QuickAskPanelController {

    private var panel: NSPanel?
    private let backend: BackendManager

    init(backend: BackendManager) {
        self.backend = backend
    }

    func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        if let screen = NSScreen.main {
            let x = screen.frame.midX - panel.frame.width / 2
            let y = screen.frame.midY - panel.frame.height / 2 + 100
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makePanel() -> NSPanel {
        let view = QuickAskView(backend: backend, onDismiss: { [weak self] in
            self?.panel?.orderOut(nil)
        })

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 80),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: view)
        return panel
    }
}