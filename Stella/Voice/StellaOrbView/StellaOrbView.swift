import SwiftUI

struct StellaOrbView: View {

    let state: VoiceConversationManager.State
    let audioLevel: Float

    @State private var rotation1: Double = 0
    @State private var rotation2: Double = 0
    @State private var breathe = false

    var body: some View {

        ZStack {

            // MARK: Ambient neon bloom

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [
                            .pink,
                            .purple,
                            .blue,
                            .orange,
                            .pink
                        ],
                        center: .center
                    ),
                    lineWidth: 14
                )
                .frame(width: 122, height: 122)
                .blur(radius: 24)
                .opacity(glowOpacity)
                .scaleEffect(glowScale)

            Circle()
                .stroke(
                    Color.purple.opacity(0.35),
                    lineWidth: 18
                )
                .frame(width: 118, height: 118)
                .blur(radius: 30)
                .scaleEffect(glowScale)

            // MARK: Transparent glass body

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white.opacity(0.04),
                            .purple.opacity(0.06),
                            .black.opacity(0.16)
                        ],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 70
                    )
                )
                .frame(width: 112, height: 112)
                .overlay {

                    Circle()
                        .stroke(
                            Color.white.opacity(0.09),
                            lineWidth: 1
                        )
                }

            // MARK: Neon outer rim

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [
                            .pink.opacity(0.95),
                            .purple,
                            .blue.opacity(0.9),
                            .orange.opacity(0.95),
                            .pink.opacity(0.95)
                        ],
                        center: .center
                    ),
                    lineWidth: 3.2
                )
                .frame(width: 112, height: 112)
                .blur(radius: 0.4)
                .rotationEffect(.degrees(rotation1))

            // MARK: Inner plasma ring

            Ellipse()
                .trim(from: 0.05, to: 0.78)
                .stroke(
                    LinearGradient(
                        colors: [
                            .clear,
                            .pink.opacity(0.95),
                            .purple,
                            .blue.opacity(0.9),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(
                        lineWidth: 5,
                        lineCap: .round
                    )
                )
                .frame(width: 88, height: 46)
                .rotationEffect(.degrees(rotation2))
                .blur(radius: 1.1)
                .blendMode(.screen)
                .opacity(plasmaOpacity)

            // MARK: Second internal streak

            Ellipse()
                .trim(from: 0.16, to: 0.68)
                .stroke(
                    LinearGradient(
                        colors: [
                            .clear,
                            .orange.opacity(0.8),
                            .pink.opacity(0.9),
                            .purple.opacity(0.7),
                            .clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    style: StrokeStyle(
                        lineWidth: 3.5,
                        lineCap: .round
                    )
                )
                .frame(width: 72, height: 94)
                .rotationEffect(.degrees(-rotation1 * 1.35))
                .blur(radius: 0.8)
                .blendMode(.screen)
                .opacity(plasmaOpacity * 0.9)

            // MARK: Hot core sparkle

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white.opacity(coreOpacity),
                            .pink.opacity(coreOpacity * 0.5),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 28
                    )
                )
                .frame(width: 56, height: 56)
                .blur(radius: 5)
                .blendMode(.screen)

            // MARK: Highlight

            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.40),
                            .white.opacity(0.04)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 42, height: 15)
                .blur(radius: 3)
                .offset(x: -18, y: -31)
                .rotationEffect(.degrees(-18))
        }
        .frame(width: 190, height: 190)
        .scaleEffect(baseScale)
        .animation(
            .easeOut(duration: 0.12),
            value: audioLevel
        )
        .animation(
            .easeInOut(duration: 0.4),
            value: state
        )
        .onAppear {

            withAnimation(
                .linear(duration: 8)
                .repeatForever(
                    autoreverses: false
                )
            ) {
                rotation1 = 360
            }

            withAnimation(
                .linear(duration: 5)
                .repeatForever(
                    autoreverses: false
                )
            ) {
                rotation2 = -360
            }

            withAnimation(
                .easeInOut(duration: 2.8)
                .repeatForever(
                    autoreverses: true
                )
            ) {
                breathe.toggle()
            }
        }
    }

    // MARK: - Audio response

    private var normalizedLevel: CGFloat {

        min(
            CGFloat(audioLevel * 16),
            0.22
        )
    }

    // MARK: - State visuals

    private var baseScale: CGFloat {

        switch state {

        case .listening:
            return 1 + normalizedLevel

        case .thinking:
            return breathe ? 0.99 : 0.96

        case .transcribing:
            return 0.96

        case .speaking:
            return breathe ? 1.03 : 1.0

        default:
            return breathe ? 1.015 : 0.99
        }
    }

    private var glowScale: CGFloat {

        switch state {

        case .listening:
            return 1.05 + normalizedLevel * 1.5

        case .thinking:
            return 1.12

        case .speaking:
            return 1.18

        default:
            return breathe ? 1.08 : 1.02
        }
    }

    private var glowOpacity: Double {

        switch state {

        case .listening:
            return 0.85

        case .thinking:
            return 0.68

        case .speaking:
            return 0.90

        case .error:
            return 0.30

        default:
            return 0.55
        }
    }

    private var plasmaOpacity: Double {

        switch state {

        case .thinking:
            return 1.0

        case .transcribing:
            return 0.95

        case .speaking:
            return 0.90

        case .listening:
            return 0.80

        default:
            return 0.55
        }
    }

    private var coreOpacity: Double {

        switch state {

        case .thinking:
            return 0.85

        case .speaking:
            return 0.75

        case .listening:
            return 0.55

        default:
            return 0.40
        }
    }
}
