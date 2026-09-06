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
    @ObservedObject var voiceManager: VoiceConversationManager

    @StateObject private var wakeWordListener: WakeWordListener

        init(
            mouseTracker: GlobalMouseTracker,
            voiceManager: VoiceConversationManager
        ) {
            self.mouseTracker = mouseTracker
            self.voiceManager = voiceManager
            _wakeWordListener = StateObject(
                wrappedValue: WakeWordListener(recorder: voiceManager.recorder)
            )
        }
    @State private var behaviorState: StellaBehaviorState = .idle
    @State private var statePulse: CGFloat = 1

    @State private var isHovering = false
    @State private var isPressed = false
    @State private var idleEyeOffset: CGSize = .zero
    @State private var squintAmount: CGFloat = 1
//    @State private var startleScale: CGFloat = 1
    
    @State private var isRoaming = false
    @State private var lastInteractionTime = Date()
    @State private var roamingEyeOffset: CGSize = .zero
    
    @State private var velocity: CGVector = .zero
    @State private var movementLean: CGFloat = 0
    @State private var movementStretch: CGFloat = 1
    @State private var dragVelocity: CGVector = .zero
    @State private var lastDragMouse: CGPoint?
    @State private var lastDragTime: Date?
    @State private var throwTask: Task<Void, Never>?
    @State private var isResting = false
    
//    @State private var releaseKick: CGSize = .zero
    @State private var startleOffset: CGFloat = 0
    @State private var eyeWidthBoost: CGFloat = 1

    @State private var blinkAmount: CGFloat = 1

    @State private var dragStartMouse: CGPoint?
    @State private var dragStartWindowOrigin: CGPoint?

    var body: some View {

        GeometryReader { geometry in
            
            
            let stellaCenter = CGPoint(
                x: geometry.size.width / 2,
                y: geometry.size.height / 2
            )
            
            let localMouse = localMousePosition()
            
            ZStack {
                
                Color.clear
                    .onChange(
                        of: mouseTracker.globalPosition
                    ) {
                        updateMouseInteraction(
                            localMouse: localMouse,
                            center: stellaCenter
                        )
                    }

                StellaBody(
                        mousePosition: localMouse,
                        center: stellaCenter,
                        blinkAmount: blinkAmount,
                        squintAmount: squintAmount,
                        idleEyeOffset: idleEyeOffset,
//                        releaseKick: releaseKick,
                        statePulse: statePulse,
                        startleOffset: startleOffset,
                        eyeWidthBoost: eyeWidthBoost,
                        behaviorState: behaviorState,
                        roamingEyeOffset: roamingEyeOffset,
                        isRoaming: isRoaming,
                        movementLean: movementLean,
                        movementStretch: movementStretch,
                        isHovering: isHovering,
                        isPressed: isPressed
                )
                .frame(
                    width: 105,
                    height: 105
                )
                
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity
            )

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
                    .onEnded { value in

                        lastInteractionTime = Date()

                        isPressed = false

                        let releaseVelocity = dragVelocity

                        dragStartMouse = nil
                        dragStartWindowOrigin = nil

                        lastDragMouse = nil
                        lastDragTime = nil

                        dragVelocity = .zero

                        throwTask?.cancel()

                        throwTask = Task {
                            await throwStella(
                                initialVelocity: releaseVelocity
                            )
                        }
                        behaviorState = .idle
                    }
            )

            .task {
                await blinkLoop()
            }
            
            .task {
                await idlePersonalityLoop(
                    
                )
            }
            .task {
                await roamingLoop()
            }
            .task {
                await assistantStatePulseLoop()
            }
            .task {
                configureVoiceLifecycle()

                async let allowed = wakeWordListener.requestPermissions()
                await voiceManager.waitUntilAudioGraphReady()

                guard await allowed else {
                    print(
                        "[CHARACTER] wake-word permissions unavailable"
                    )
                    return
                }

                guard voiceManager.state == .idle else {
                    return
                }

                wakeWordListener.start()
            }
            
            .onChange(
                of: voiceManager.state
            ) { newState in

                syncBehaviorWithVoice(
                    newState
                )
            }
        }
        .background(Color.clear)
    }
    
    // MARK: - Voice integration

    private func configureVoiceLifecycle() {

        // Wake standby -> active Stella
        wakeWordListener.onWakeWordDetected = {

            print(
                "[CHARACTER] wake word detected"
            )

            lastInteractionTime = Date()

            // Stop autonomous physical behavior from competing
            // with Stella's conversational state.
            throwTask?.cancel()
            throwTask = nil

            isResting = false
            isRoaming = false

            triggerVoiceWake()

            Task { @MainActor in

                // Give WakeWordListener time to fully release
                // AVAudioEngine before Whisper grabs the mic.
                try? await Task.sleep(
                    for: .milliseconds(300)
                )

                print(
                    "[CHARACTER] starting voice conversation"
                )

                voiceManager
                    .beginConversation()
            }
        }


        // Active Stella -> wake standby
        voiceManager.onVoiceSessionEnded = {

            print(
                "[CHARACTER] conversation ended"
            )

            lastInteractionTime = Date()

            behaviorState = .idle

            Task { @MainActor in

                // Give MicrophoneRecorder time to release
                // the microphone before wake detection resumes.
                try? await Task.sleep(
                    for: .milliseconds(300)
                )

                guard
                    voiceManager.state == .idle
                else {
                    return
                }

                print(
                    "[CHARACTER] returning to wake standby"
                )

                wakeWordListener.start()
            }
        }
    }
    
    private func syncBehaviorWithVoice(
        _ voiceState:
            VoiceConversationManager.State
    ) {

        switch voiceState {

        case .loading:

            break


        case .idle:

            // Don't interrupt a physical mouse interaction.
            if isPressed {
                return
            }

            behaviorState = .idle


        case .greeting:

            stopAutonomousBehavior()

            behaviorState = .listening


        case .listening:

            stopAutonomousBehavior()

            behaviorState = .listening


        case .transcribing:

            stopAutonomousBehavior()

            behaviorState = .thinking


        case .thinking:

            stopAutonomousBehavior()

            behaviorState = .thinking


        case .speaking:

            stopAutonomousBehavior()

            behaviorState = .speaking


        case .error:

            behaviorState = .idle
        }
    }
    
    private func stopAutonomousBehavior() {

        throwTask?.cancel()
        throwTask = nil

        isResting = false
        isRoaming = false

        velocity = .zero

        withAnimation(
            .spring(
                response: 0.30,
                dampingFraction: 0.65
            )
        ) {

            movementLean = 0
            movementStretch = 1
            roamingEyeOffset = .zero

            squintAmount = 1
            idleEyeOffset = .zero
        }
    }
    private func idlePersonalityLoop() async {

        while !Task.isCancelled {

            let delay = Double.random(in: 3.0...7.0)

            try? await Task.sleep(
                for: .seconds(delay)
            )
            
            guard behaviorState == .idle,
                  voiceManager.state == .idle
            else {
                continue
            }

            guard !isPressed,
                  !isRoaming,
                  !isResting else {
                continue
            }

            let action = Int.random(in: 0...2)

            switch action {

            case 0:
                await wanderEyes()

            case 1:
                await doubleBlink()

            case 2:
                await curiousSquint()

            default:
                break
            }
        }
    }
    
    private func roamingLoop() async {

        while !Task.isCancelled {

            let delay = Double.random(in: 8...18)

            try? await Task.sleep(
                for: .seconds(delay)
            )

            guard !isPressed,
                  !isRoaming,
                  !isResting else {
                continue
            }
            guard behaviorState == .idle,
                  voiceManager.state == .idle
            else {
                continue
            }

            let timeSinceInteraction =
                Date().timeIntervalSince(lastInteractionTime)

            guard timeSinceInteraction > 5 else {
                continue
            }

            await roamToNearbyPoint()
        }
    }
    
    private func assistantStatePulseLoop() async {

        while !Task.isCancelled {

            if behaviorState == .speaking {

                await MainActor.run {
                    withAnimation(
                        .easeInOut(duration: 0.16)
                    ) {
                        statePulse = 1.045
                    }
                }

                try? await Task.sleep(
                    for: .milliseconds(160)
                )

                await MainActor.run {
                    withAnimation(
                        .easeInOut(duration: 0.18)
                    ) {
                        statePulse = 0.985
                    }
                }

                try? await Task.sleep(
                    for: .milliseconds(180)
                )
                

            } else {

                await MainActor.run {
                    statePulse = 1
                }

                try? await Task.sleep(
                    for: .milliseconds(120)
                )
            }
        }
    
    }
    
    private func roamToNearbyPoint() async {

        guard let window = NSApp.windows.first(where: {
            $0 is StellaPanel
        }) else {
            return
        }

        guard let screen = window.screen ?? NSScreen.main else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let currentOrigin = window.frame.origin
        let windowSize = window.frame.size

        let maxTravel: CGFloat = 220
        let edgePadding: CGFloat = 45

        let randomX = CGFloat.random(
            in: -maxTravel...maxTravel
        )

        let randomY = CGFloat.random(
            in: -maxTravel...maxTravel
        )

        var targetX =
            currentOrigin.x + randomX

        var targetY =
            currentOrigin.y + randomY

        targetX = min(
            max(
                targetX,
                visibleFrame.minX + edgePadding
            ),
            visibleFrame.maxX
                - windowSize.width
                - edgePadding
        )

        targetY = min(
            max(
                targetY,
                visibleFrame.minY + edgePadding
            ),
            visibleFrame.maxY
                - windowSize.height
                - edgePadding
        )

        let target = CGPoint(
            x: targetX,
            y: targetY
        )

        await animateWindow(
            window,
            to: target
        )
        
    }
    
    private func animateWindow(
        _ window: NSWindow,
        to target: CGPoint
    ) async {

        isRoaming = true
        behaviorState = .roaming
        var position = window.frame.origin

        velocity = .zero
        // if the movement feels too fast, reduce:
        let maxSpeed: CGFloat = 260
        // If she feels too floaty, increase:
        let acceleration: CGFloat = 520
        let brakingDistance: CGFloat = 130
        let stopDistance: CGFloat = 3

        let dt: CGFloat = 1.0 / 60.0

        while !Task.isCancelled {

            guard !isPressed else {
                break
            }
            guard voiceManager.state == .idle else {
                    break
                }

            let dx = target.x - position.x
            let dy = target.y - position.y

            let distance = sqrt(
                dx * dx +
                dy * dy
            )

            if distance < stopDistance {

                position = target

                await MainActor.run {
                    window.setFrameOrigin(target)
                }

                break
            }

            let directionX = dx / max(distance, 1)
            let directionY = dy / max(distance, 1)

            var desiredSpeed = maxSpeed

            if distance < brakingDistance {
                desiredSpeed =
                    maxSpeed *
                    (distance / brakingDistance)
            }

            let desiredVelocity = CGVector(
                dx: directionX * desiredSpeed,
                dy: directionY * desiredSpeed
            )

            let velocityDX =
                desiredVelocity.dx - velocity.dx

            let velocityDY =
                desiredVelocity.dy - velocity.dy

            let velocityDifference = sqrt(
                velocityDX * velocityDX +
                velocityDY * velocityDY
            )

            if velocityDifference > 0 {

                let maxVelocityChange =
                    acceleration * dt

                let scale = min(
                    maxVelocityChange / velocityDifference,
                    1
                )

                velocity.dx +=
                    velocityDX * scale

                velocity.dy +=
                    velocityDY * scale
            }

            let speed = sqrt(
                velocity.dx * velocity.dx +
                velocity.dy * velocity.dy
            )

            if speed > maxSpeed {

                let scale =
                    maxSpeed / speed

                velocity.dx *= scale
                velocity.dy *= scale
            }

            position.x += velocity.dx * dt
            position.y += velocity.dy * dt

            await MainActor.run {

                window.setFrameOrigin(position)

                updateMovementExpression()
            }

            try? await Task.sleep(
                for: .milliseconds(16)
            )
        }

        await MainActor.run {

            velocity = .zero

            withAnimation(
                .spring(
                    response: 0.35,
                    dampingFraction: 0.62
                )
            ) {
                movementLean = 0
                movementStretch = 1
                roamingEyeOffset = .zero
            }

            isRoaming = false
            if voiceManager.state == .idle {
                behaviorState = .idle
            } else {
                syncBehaviorWithVoice(
                    voiceManager.state
                )
            }
        }
            if Bool.random() {
                await settleForAWhile()
        }
    }
    
    private func settleForAWhile() async {

        isResting = true
        behaviorState = .resting

        withAnimation(
            .easeInOut(duration: 0.5)
        ) {
            squintAmount = 0.82
            idleEyeOffset = CGSize(
                width: 0,
                height: 2
            )
        }

        let restTime = Double.random(
            in: 2.5...6.0
        )

        try? await Task.sleep(
            for: .seconds(restTime)
        )
        
        guard voiceManager.state == .idle else {

            await MainActor.run {

                isResting = false
                squintAmount = 1
                idleEyeOffset = .zero

                syncBehaviorWithVoice(
                    voiceManager.state
                )
            }

            return
        }

        await MainActor.run {

            withAnimation(
                .easeInOut(duration: 0.45)
            ) {
                squintAmount = 1
                idleEyeOffset = .zero
            }

            isResting = false
            if voiceManager.state == .idle {
                behaviorState = .idle
            } else {
                syncBehaviorWithVoice(
                    voiceManager.state
                )
            }
        }
    }
    
    private func updateMovementExpression() {

        let speed = sqrt(
            velocity.dx * velocity.dx +
            velocity.dy * velocity.dy
        )

        guard speed > 1 else {

            movementLean = 0
            movementStretch = 1

            return
        }

        let normalizedX =
            velocity.dx / speed

        let normalizedY =
            velocity.dy / speed

        movementLean =
            max(
                -7,
                min(
                    7,
                    normalizedX * 7
                )
            )

        let speedRatio =
            min(
                speed / 260,
                1
            )

        movementStretch =
            1 + speedRatio * 0.08

        roamingEyeOffset = CGSize(
            width: normalizedX * 7,
            height: -normalizedY * 5
        )
    }
    
    private func smoothStep(
        _ t: CGFloat
    ) -> CGFloat {

        return t * t * (3 - 2 * t)
    }
    
    private func wanderEyes() async {

        let offset = CGSize(
            width: CGFloat.random(in: -7...7),
            height: CGFloat.random(in: -5...5)
        )

        await MainActor.run {
            withAnimation(
                .easeInOut(duration: 0.5)
            ) {
                idleEyeOffset = offset
            }
        }

        try? await Task.sleep(
            for: .milliseconds(1100)
        )

        await MainActor.run {
            withAnimation(
                .easeInOut(duration: 0.6)
            ) {
                idleEyeOffset = .zero
            }
        }
    }
    
    private func curiousSquint() async {
        
        behaviorState = .curious
        await MainActor.run {
            withAnimation(
                .spring(
                    response: 0.18,
                    dampingFraction: 0.65
                )
            ) {
                squintAmount = 0.38
            }
        }

        try? await Task.sleep(
            for: .milliseconds(700)
        )

        await MainActor.run {
            withAnimation(
                .spring(
                    response: 0.30,
                    dampingFraction: 0.7
                )
            ) {
                squintAmount = 1
            }
        }
        behaviorState = .idle
    }
    
    private func doubleBlink() async {

        for _ in 0..<2 {

            await MainActor.run {
                withAnimation(
                    .easeInOut(duration: 0.06)
                ) {
                    blinkAmount = 0.08
                }
            }

            try? await Task.sleep(
                for: .milliseconds(90)
            )

            await MainActor.run {
                withAnimation(
                    .easeInOut(duration: 0.07)
                ) {
                    blinkAmount = 1
                }
            }

            try? await Task.sleep(
                for: .milliseconds(120)
            )
        }
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
    
    private func triggerVoiceWake() {

        behaviorState = .startled

        withAnimation(
            .spring(
                response: 0.12,
                dampingFraction: 0.45
            )
        ) {

            startleOffset = -9
            eyeWidthBoost = 1.22
        }

        Task {

            try? await Task.sleep(
                for: .milliseconds(120)
            )

            await MainActor.run {

                withAnimation(
                    .spring(
                        response: 0.32,
                        dampingFraction: 0.55
                    )
                ) {

                    startleOffset = 0
                    eyeWidthBoost = 1
                }

                // Wake animation finishes in an attentive state,
                // never back in idle.
                behaviorState = .listening
            }
        }
    }
    
    private func triggerStartle() {
        
        behaviorState = .startled

        withAnimation(
            .spring(
                response: 0.12,
                dampingFraction: 0.45
            )
        ) {
            startleOffset = -9
            eyeWidthBoost = 1.22
        }

        Task {

            try? await Task.sleep(
                for: .milliseconds(120)
            )

            await MainActor.run {

                withAnimation(
                    .spring(
                        response: 0.32,
                        dampingFraction: 0.55
                    )
                ) {
                    startleOffset = 0
                    eyeWidthBoost = 1
                }
                if isPressed {
                        behaviorState = .grabbed
                } else {
                        behaviorState = .idle
                }
            }
        }
    }
    
    
    private var canIdleAct: Bool {
        behaviorState == .idle
    }
    
    private var canAutonomouslyMove: Bool {
        behaviorState == .idle
    }
    
    // MARK: - Dragging

    private func handleDrag(_ value: DragGesture.Value) {
        
        lastInteractionTime = Date()

        guard let window = NSApp.windows.first(where: {
            $0 is StellaPanel
        }) else {
            return
        }

        isPressed = true

        if dragStartMouse == nil {
            
            behaviorState = .grabbed
            
            throwTask?.cancel()
            throwTask = nil

            dragVelocity = .zero
            lastDragMouse = NSEvent.mouseLocation
            lastDragTime = Date()
            
            triggerStartle()

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
        let now = Date()

        if let previousMouse = lastDragMouse,
           let previousTime = lastDragTime {

            let dt = now.timeIntervalSince(previousTime)

            if dt > 0 {

                let rawVelocity = CGVector(
                    dx: (currentMouse.x - previousMouse.x) / dt,
                    dy: (currentMouse.y - previousMouse.y) / dt
                )

                // Smooth it slightly so tiny mouse jitter
                // doesn't create absurd throw speeds.
                dragVelocity.dx =
                    dragVelocity.dx * 0.65 +
                    rawVelocity.dx * 0.35

                dragVelocity.dy =
                    dragVelocity.dy * 0.65 +
                    rawVelocity.dy * 0.35
            }
        }

        lastDragMouse = currentMouse
        lastDragTime = now
        behaviorState = .thrown
        
        let dx = currentMouse.x - startMouse.x
        let dy = currentMouse.y - startMouse.y

        window.setFrameOrigin(
            CGPoint(
                x: startOrigin.x + dx,
                y: startOrigin.y + dy
            )
        )
    }
    
    private func throwStella(
        initialVelocity: CGVector
    ) async {

        guard let window = NSApp.windows.first(where: {
            $0 is StellaPanel
        }) else {
            return
        }

        guard let screen = window.screen ?? NSScreen.main else {
            return
        }

        var position = window.frame.origin
        var throwVelocity = initialVelocity

        let frame = screen.visibleFrame
        let windowSize = window.frame.size

        let dt: CGFloat = 1.0 / 60.0
        // If she travels too far, lower:
        let friction: CGFloat = 0.965
        // if edge impacts feel too bouncy, reduce:
        let bounceDamping: CGFloat = 0.42
        let stopSpeed: CGFloat = 18
        let maxThrowSpeed: CGFloat = 1500

        // Clamp ridiculous trackpad/mouse spikes.
        let initialSpeed = sqrt(
            throwVelocity.dx * throwVelocity.dx +
            throwVelocity.dy * throwVelocity.dy
        )

        if initialSpeed > maxThrowSpeed {

            let scale =
                maxThrowSpeed / initialSpeed

            throwVelocity.dx *= scale
            throwVelocity.dy *= scale
        }

        isRoaming = true

        while !Task.isCancelled {

            guard !isPressed else {
                break
            }

            let speed = sqrt(
                throwVelocity.dx * throwVelocity.dx +
                throwVelocity.dy * throwVelocity.dy
            )

            if speed < stopSpeed {
                break
            }

            position.x +=
                throwVelocity.dx * dt

            position.y +=
                throwVelocity.dy * dt

            let minX = frame.minX
            let maxX =
                frame.maxX - windowSize.width

            let minY = frame.minY
            let maxY =
                frame.maxY - windowSize.height

            var bounced = false

            if position.x < minX {

                position.x = minX

                throwVelocity.dx =
                    abs(throwVelocity.dx) *
                    bounceDamping

                bounced = true
            }

            if position.x > maxX {

                position.x = maxX

                throwVelocity.dx =
                    -abs(throwVelocity.dx) *
                    bounceDamping

                bounced = true
            }

            if position.y < minY {

                position.y = minY

                throwVelocity.dy =
                    abs(throwVelocity.dy) *
                    bounceDamping

                bounced = true
            }

            if position.y > maxY {

                position.y = maxY

                throwVelocity.dy =
                    -abs(throwVelocity.dy) *
                    bounceDamping

                bounced = true
            }

            throwVelocity.dx *= friction
            throwVelocity.dy *= friction

            velocity = throwVelocity

            await MainActor.run {

                window.setFrameOrigin(position)

                updateMovementExpression()

                if bounced {
                    triggerEdgeBounce()
                }
            }

            try? await Task.sleep(
                for: .milliseconds(16)
            )
        }

        await MainActor.run {

            velocity = .zero

            withAnimation(
                .spring(
                    response: 0.34,
                    dampingFraction: 0.55
                )
            ) {
                movementLean = 0
                movementStretch = 1
                roamingEyeOffset = .zero
            }

            isRoaming = false
        }
    }
    
    private func triggerEdgeBounce() {

        withAnimation(
            .spring(
                response: 0.12,
                dampingFraction: 0.42
            )
        ) {
            movementStretch = 1.12
        }

        Task {

            try? await Task.sleep(
                for: .milliseconds(90)
            )

            await MainActor.run {

                withAnimation(
                    .spring(
                        response: 0.28,
                        dampingFraction: 0.6
                    )
                ) {
                    movementStretch = 1
                }
            }
        }
    }
    
    private func updateMouseInteraction(
        localMouse: CGPoint,
        center: CGPoint
    ) {

        guard let window = NSApp.windows.first(where: {
            $0 is StellaPanel
        }) else {
            return
        }

        let dx = localMouse.x - center.x
        let dy = localMouse.y - center.y

        let distance = sqrt(
            dx * dx +
            dy * dy
        )

        // Stella body is roughly 105px wide.
        let interactionRadius: CGFloat = 58

        window.ignoresMouseEvents =
            distance > interactionRadius
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
        let squintAmount: CGFloat

        let idleEyeOffset: CGSize
        let statePulse: CGFloat
//        let startleScale: CGFloat
//        let releaseKick: CGSize
        
        let startleOffset: CGFloat
        let eyeWidthBoost: CGFloat
        let behaviorState: StellaBehaviorState
        
        let roamingEyeOffset: CGSize
        let isRoaming: Bool
        
        let movementLean: CGFloat
        let movementStretch: CGFloat

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
        
        private var cursorIsTouching: Bool {
            cursorDistance < 58
        }
        
        private var stateScale: CGFloat {
            switch behaviorState {
            case .listening:
                return 1.04

            case .thinking:
                return 0.97

            case .speaking:
                return 1.06

            default:
                return 1
            }
        }

        private var stateEyeSpacing: CGFloat {
            switch behaviorState {
            case .listening:
                return 26

            case .thinking:
                return 18

            case .speaking:
                return 24

            default:
                return 22
            }
        }

        private var stateGlowBoost: CGFloat {
            switch behaviorState {
            case .listening:
                return 1.15

            case .thinking:
                return 0.75

            case .speaking:
                return 1.35

            default:
                return 1
            }
        }
        
        
        private var eyeOffset: CGSize {
            
            if isRoaming {
                    return roamingEyeOffset
                }
            
            // If cursor is far away, Stella is free to idle-look around.
            if cursorDistance > 210 {
                return idleEyeOffset
            }

            let dx = mousePosition.x - center.x
            let dy = mousePosition.y - center.y

            let distance = sqrt(
                dx * dx +
                dy * dy
            )

            guard distance > 1 else {
                return idleEyeOffset
            }

            let maxDistance: CGFloat = 8

            return CGSize(
                width: (dx / distance) * maxDistance,
                height: (dy / distance) * maxDistance
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


                // Wide atmospheric glow
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
                        lineWidth: 6
                    )
                    .blur(radius: 18)
                    .opacity(0.28 * stateGlowBoost)


                // Closer neon glow
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
                        lineWidth: 5
                    )
                    .blur(radius: 7)
                    .opacity(0.55 * stateGlowBoost)
                
                //crisp ring
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
                        lineWidth: 5
                    )
                


                // Eyes
                HStack(spacing: stateEyeSpacing) {

                    StellaEye(
                        blinkAmount: blinkAmount,
                        squintAmount: squintAmount,
                        widthBoost: eyeWidthBoost
                    )

                    StellaEye(
                        blinkAmount: blinkAmount,
                        squintAmount: squintAmount,
                        widthBoost: eyeWidthBoost
                    )
                }
                .scaleEffect(stateScale)
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
            
            .scaleEffect(
                x: isPressed
                    ? 1.10
                    : cursorIsTouching
                        ? 1.03
                        : 1,

                y: isPressed
                    ? 0.88
                    : cursorIsTouching
                        ? 0.97
                        : 1
            )
            
            .scaleEffect(
                behaviorState == .speaking
                    ? statePulse
                    : 1
            )
            
            .offset(
                x: cursorIsTouching && !isPressed
                    ? -(mousePosition.x - center.x) * 0.035
                    : 0,

                y: cursorIsTouching && !isPressed
                    ? -(mousePosition.y - center.y) * 0.035
                    : 0
            )
            .offset(
                x:
//                    releaseKick.width
//                    +
                    (
                        cursorIsTouching && !isPressed
                            ? -(mousePosition.x - center.x) * 0.035
                            : 0
                    ),

                y:
                    startleOffset
                    +
//                    releaseKick.height
//                    +
                    (
                        cursorIsTouching && !isPressed
                            ? -(mousePosition.y - center.y) * 0.035
                            : 0
                    )
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
//            .scaleEffect(startleScale)
            
            .scaleEffect(
                x: isRoaming
                    ? movementStretch
                    : 1,

                y: isRoaming
                    ? 1 / movementStretch
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
            
            .rotationEffect(
                .degrees(
                    isRoaming
                        ? Double(movementLean)
                        : 0
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
        let squintAmount: CGFloat
        let widthBoost: CGFloat

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
                .scaleEffect(
                    x: squintAmount < 1 ? 1.10 : 1,
                    y: squintAmount
                )

                .shadow(
                    color: .blue.opacity(0.7),
                    radius: 8
                )
        }
    }
}
