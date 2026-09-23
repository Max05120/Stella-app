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
    private let voiceManager: VoiceConversationManager
    
    init(
            voiceManager: VoiceConversationManager
        ) {
            self.voiceManager = voiceManager
        }

    func show() {
        guard panel == nil else { return }

        let size = NSSize(width: 320, height: 320)

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
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(
            rootView: StellaDesktopView(
                mouseTracker: mouseTracker,
                voiceManager: voiceManager
            )
        )

        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor =
            NSColor.clear.cgColor

        panel.level = .floating

        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]

        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        
        mouseTracker.start()
        
//        panel.contentView = NSHostingView(
//            rootView: StellaDesktopView(
//                mouseTracker: mouseTracker,
//                voiceManager: voiceManager
//            )
//        )

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
