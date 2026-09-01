//
//  StellaVoiceView.swift
//  Stella
//
//  Created by Harish Maheshwaran on 30/08/26.
//


import SwiftUI


struct StellaVoiceView: View {
    
    @ObservedObject
    var manager:
        VoiceConversationManager

    var onDismiss:
        () -> Void

    var body: some View {

        VStack(
            spacing: 22
        ) {

            HStack {

                Image(
                    systemName: "sparkles"
                )
                .font(
                    .system(size: 18)
                )

                Text("Stella")
                    .font(
                        .system(
                            size: 18,
                            weight: .semibold
                        )
                    )

                Spacer()

                Button {
                    manager
                        .stopConversation()

                    onDismiss()
                } label: {

                    Image(
                        systemName:
                            "xmark.circle.fill"
                    )
                    .foregroundStyle(
                        .secondary
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            StellaPlasmaOrb(
                state: manager.state,
                spectrum: manager.spectrum
            )
            .frame(
                width: 190,
                height: 190
            )

            Text(
                manager.statusText
            )
            .font(
                .system(
                    size: 17,
                    weight: .medium
                )
            )

            conversationText

            Spacer()
        }
        .padding(22)
        .frame(
            width: 460,
            height: 390
        )
        .background {
            ZStack {
                Color.black.opacity(0.72)
                Rectangle()
                    .fill(.ultraThinMaterial)
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: 24,
                style: .continuous
            )
        )
        .onAppear {
            manager
                .beginConversation()
        }
        .onExitCommand {

            manager
                .stopConversation()

            onDismiss()
        }
    }

    private var voiceIndicator:
        some View
    {

        ZStack {

            Circle()
                .fill(
                    .primary
                        .opacity(0.06)
                )
                .frame(
                    width: 110,
                    height: 110
                )

            Circle()
                .fill(
                    .primary
                        .opacity(0.10)
                )
                .frame(
                    width: 78,
                    height: 78
                )
                .scaleEffect(
                    indicatorScale
                )
                .animation(
                    .easeOut(
                        duration: 0.12
                    ),
                    value:
                        manager.audioLevel
                )

            Image(
                systemName:
                    indicatorIcon
            )
            .font(
                .system(size: 30)
            )
        }
    }

    private var indicatorScale:
        CGFloat
    {
        guard
            manager.state ==
                .listening
        else {
            return 1
        }

        let amplified =
            min(
                CGFloat(
                    manager.audioLevel * 25
                ),
                0.45
            )

        return 1 + amplified
    }

    private var indicatorIcon:
        String
    {
        switch manager.state {

        case .listening:
            return "waveform"

        case .thinking,
             .transcribing:
            return "sparkles"

        case .speaking:
            return "speaker.wave.2.fill"

        case .error:
            return "exclamationmark"

        default:
            return "sparkles"
        }
    }

    @ViewBuilder
    private var conversationText:
        some View
    {

        if !manager.responseText.isEmpty {

            Text(
                manager.responseText
            )
            .font(
                .system(size: 14)
            )
            .foregroundStyle(
                .secondary
            )
            .lineLimit(3)
            .multilineTextAlignment(
                .center
            )

        } else if
            !manager.transcript.isEmpty
        {

            Text(
                "“\(manager.transcript)”"
            )
            .font(
                .system(size: 14)
            )
            .foregroundStyle(
                .secondary
            )
            .lineLimit(2)
            .multilineTextAlignment(
                .center
            )
        }
    }
}
