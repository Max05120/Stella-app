//
//  StellaDesktopView.swift
//  Stella
//
//  Created by Harish Maheshwaran on 01/09/26.
//


import SwiftUI
import AppKit

struct StellaDesktopView: View {

    @ObservedObject var mouseTracker: GlobalMouseTracker

    @State private var isHovering = false
    @State private var isPressed = false

    @State private var blinkAmount: CGFloat = 1

    @State private var dragStartMouse: CGPoint?
    @State private var dragStartWindowOrigin: CGPoint?

    var body: some View {

        GeometryReader { geometry in
            
            let center = CGPoint(
                x: geometry.size.width / 2,
                y: geometry.size.height / 2
            )
            
            let localMouse = localMousePosition()
            
            ZStack {

                StellaBody(
                    mousePosition: localMouse,
                    center: center,
                    blinkAmount: blinkAmount,
                    isHovering: isHovering,
                    isPressed: isPressed
                )
                .frame(
                    width: 125,
                    height: 125
                )
            }

            .contentShape(Circle())

            .onContinuousHover { phase in
                switch phase {

                case .active:
                    isHovering = true

                case .ended:
                    isHovering = false
                }
            }

            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleDrag(value)
                    }
                    .onEnded { _ in
                        isPressed = false
                        dragStartMouse = nil
                        dragStartWindowOrigin = nil
                    }
            )

            .task {
                await blinkLoop()
            }
        }
        .background(Color.clear)
    }
    
    private func localMousePosition() -> CGPoint {

        guard let window = NSApp.windows.first(where: {
            $0 is StellaPanel
        }) else {
            return .zero
        }

        let global = mouseTracker.globalPosition

        return CGPoint(
            x: global.x - window.frame.minX,
            y: window.frame.maxY - global.y
        )
    }

    // MARK: - Dragging

    private func handleDrag(_ value: DragGesture.Value) {

        guard let window = NSApp.windows.first(where: {
            $0 is StellaPanel
        }) else {
            return
        }

        isPressed = true

        if dragStartMouse == nil {

            dragStartMouse = NSEvent.mouseLocation
            dragStartWindowOrigin = window.frame.origin
        }

        guard
            let startMouse = dragStartMouse,
            let startOrigin = dragStartWindowOrigin
        else {
            return
        }

        let currentMouse = NSEvent.mouseLocation

        let dx = currentMouse.x - startMouse.x
        let dy = currentMouse.y - startMouse.y

        window.setFrameOrigin(
            CGPoint(
                x: startOrigin.x + dx,
                y: startOrigin.y + dy
            )
        )
    }


    // MARK: - Blink

    private func blinkLoop() async {

        while !Task.isCancelled {

            let delay = Double.random(in: 2.5...6.5)

            try? await Task.sleep(
                for: .seconds(delay)
            )

            await MainActor.run {

                withAnimation(
                    .easeInOut(duration: 0.07)
                ) {
                    blinkAmount = 0.08
                }
            }

            try? await Task.sleep(
                for: .milliseconds(100)
            )

            await MainActor.run {

                withAnimation(
                    .easeInOut(duration: 0.09)
                ) {
                    blinkAmount = 1
                }
            }
        }
    }
    private struct StellaBody: View {

        let mousePosition: CGPoint
        let center: CGPoint

        let blinkAmount: CGFloat

        let isHovering: Bool
        let isPressed: Bool
        
        private var cursorDistance: CGFloat {

            let dx = mousePosition.x - center.x
            let dy = mousePosition.y - center.y

            return sqrt(
                dx * dx +
                dy * dy
            )
        }


        private var cursorIsNear: Bool {
            cursorDistance < 180
        }


        private var cursorIsVeryNear: Bool {
            cursorDistance < 90
        }

        private var eyeOffset: CGSize {

            let dx = mousePosition.x - center.x
            let dy = mousePosition.y - center.y

            let distance = sqrt(
                dx * dx +
                dy * dy
            )

            guard distance > 1 else {
                return .zero
            }

            let maxDistance: CGFloat = 7

            let normalizedX = dx / distance
            let normalizedY = dy / distance

            let proximity = min(
                distance / 220,
                1
            )

            let strength =
                maxDistance * (1 - proximity * 0.35)

            return CGSize(
                width: normalizedX * strength,
                height: normalizedY * strength
            )
        }

        var body: some View {

            ZStack {

                // Outer energy glow
                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [
                                .purple,
                                .blue,
                                .purple,
                                .red,
                                .pink,
                                .purple
                            ],
                            center: .center
                        ),
                        lineWidth: 12
                    )
                    .blur(radius: 14)
                    .opacity(0.8)


                // Main Stella body
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.black.opacity(0.70),
                                Color.black.opacity(0.92)
                            ],
                            center: .center,
                            startRadius: 4,
                            endRadius: 85
                        )
                    )


                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [
                                Color.purple,
                                Color.blue,
                                Color.purple,
                                Color.red,
                                Color.pink,
                                Color.purple
                            ],
                            center: .center
                        ),
                        lineWidth: 8
                    )
                    .blur(radius: 10)
                    .opacity(0.55)


                // Eyes
                HStack(spacing: 22) {

                    StellaEye(
                        blinkAmount: blinkAmount
                    )

                    StellaEye(
                        blinkAmount: blinkAmount
                    )
                }
                .offset(eyeOffset)
                .animation(
                    .interactiveSpring(
                        response: 0.18,
                        dampingFraction: 0.72
                    ),
                    value: eyeOffset.width
                )
                .animation(
                    .interactiveSpring(
                        response: 0.18,
                        dampingFraction: 0.72
                    ),
                    value: eyeOffset.height
                )
            }

            .padding(10)

            .scaleEffect(
                x: isPressed ? 1.08 : 1,
                y: isPressed ? 0.90 : 1
            )

            .scaleEffect(
                isPressed
                    ? 1
                    : cursorIsVeryNear
                        ? 1.06
                        : cursorIsNear
                            ? 1.025
                            : 1
            )
            .rotationEffect(
                .degrees(
                    isPressed
                        ? 0
                        : Double(
                            max(
                                -4,
                                min(
                                    4,
                                    (mousePosition.x - center.x) / 45
                                )
                            )
                        )
                )
            )

            .animation(
                .spring(
                    response: 0.28,
                    dampingFraction: 0.58
                ),
                value: isPressed
            )

            .animation(
                .easeOut(duration: 0.18),
                value: isHovering
            )
        }
    }


    private struct StellaEye: View {

        let blinkAmount: CGFloat

        var body: some View {

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            .white,
                            Color(
                                red: 0.72,
                                green: 0.80,
                                blue: 1
                            )
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                .frame(
                    width: 17,
                    height: 46 * blinkAmount
                )

                .shadow(
                    color: .blue.opacity(0.7),
                    radius: 8
                )
        }
    }
}
