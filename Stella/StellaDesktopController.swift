//
//  StellaDesktopController.swift
//  Stella
//
//  Created by Harish Maheshwaran on 01/09/26.
//


import AppKit
import SwiftUI

@MainActor
final class StellaDesktopController {

    private var panel: StellaPanel?
    private let mouseTracker = GlobalMouseTracker()

    func show() {
        guard panel == nil else { return }

        let size = NSSize(width: 180, height: 180)

        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)

        let origin = NSPoint(
            x: visibleFrame.maxX - size.width - 80,
            y: visibleFrame.midY - size.height / 2
        )

        let panel = StellaPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false

        panel.level = .floating

        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]

        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        
        mouseTracker.start()
        
        panel.contentView = NSHostingView(
            rootView: StellaDesktopView(
                mouseTracker: mouseTracker
            )
        )

        panel.orderFrontRegardless()

        self.panel = panel
    }

    func hide() {
        mouseTracker.stop()
        panel?.orderOut(nil)
    }
}


final class StellaPanel: NSPanel {

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}
