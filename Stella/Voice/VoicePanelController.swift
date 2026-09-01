//
//  VoicePanelController.swift
//  Stella
//
//  Created by Harish Maheshwaran on 30/08/26.
//


import AppKit
import SwiftUI

@MainActor
final class VoicePanelController {

    private var panel:
        NSPanel?

    private let manager:
        VoiceConversationManager

    init(
        backend: BackendManager
    ) {

        self.manager =
            VoiceConversationManager(
                backend: backend
            )
    }

    func toggle() {

        if let panel,
           panel.isVisible
        {
            hide()
        } else {
            show()
        }
    }

    func show() {

        let panel =
            self.panel ??
            makePanel()

        self.panel = panel

        position(panel)

        panel.makeKeyAndOrderFront(
            nil
        )

        NSApp.activate(
            ignoringOtherApps: true
        )
    }

    func hide() {

        manager
            .stopConversation()

        panel?.orderOut(nil)
    }

    private func position(
        _ panel: NSPanel
    ) {

        guard let screen =
                NSScreen.main
        else {
            return
        }

        let frame =
            screen.visibleFrame

        let x =
            frame.midX -
            panel.frame.width / 2

        // Slightly above center,
        // similar to Siri/Spotlight.
        let y =
            frame.midY -
            panel.frame.height / 2
            + 120

        panel.setFrameOrigin(
            NSPoint(
                x: x,
                y: y
            )
        )
    }

    private func makePanel()
        -> NSPanel
    {

        let view =
            StellaVoiceView(
                manager: manager
            ) {
                [weak self] in

                self?
                    .hide()
            }

        let panel =
            NSPanel(
                contentRect:
                    NSRect(
                        x: 0,
                        y: 0,
                        width: 460,
                        height: 390
                    ),

                styleMask: [
                    .nonactivatingPanel,
                    .fullSizeContentView
                ],

                backing:
                    .buffered,

                defer:
                    false
            )

        panel.isOpaque = false

        panel.backgroundColor =
            .clear

        panel.hasShadow = true

        panel.level =
            .floating

        panel.hidesOnDeactivate =
            false

        panel.isReleasedWhenClosed =
            false

        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]

        panel.contentView =
            NSHostingView(
                rootView: view
            )

        return panel
    }
}
