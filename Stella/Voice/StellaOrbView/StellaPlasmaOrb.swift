//
//  StellaPlasmaOrb.swift
//  Stella
//
//  Second pass, addressing three specific notes:
//
//  1. "colours change immediately between states" — every numeric property
//     (turbulence, flow speed, hue, saturation, brightness, breathing/ring
//     amounts) now crossfades over `transitionDuration` seconds whenever
//     `state` changes, instead of snapping. See `blend(_:_:_:)` and the
//     `.onChange(of: state)` handler below.
//
//  2. "plasma is just rotating left to right" — the old version applied one
//     continuous rotateAroundY to the whole assembly, so the dominant motion
//     you saw was a rigid spin. That's gone. What moves now is a traveling
//     wave that circulates *along* each band (phase term `time * flowSpeed`
//     inside the wave math) — the structure itself only gently sways side to
//     side, it doesn't keep spinning in one direction.
//
//  3. "wiring is scrambled / unusually connected" — the old version gave
//     every strand a fully independent random 3D axis (Fibonacci-sphere
//     distribution), which is what produced the tangled-steel-wool look:
//     every loop sat in a different, unrelated plane. Bands now share one
//     family of orientations (all are rotations of the same axis around a
//     single shared axis — think latitude lines at different tilts), so
//     they read as layered, flowing ribbons instead of crossed wires. The
//     front/back depth cue is also now a smooth per-segment fade instead of
//     a hard path break, which removes the choppy "disconnected" artifacts.
//
//  ASSUMPTION (carried over): VoiceConversationManager.State has cases
//  .loading, .idle, .greeting, .listening, .transcribing, .thinking,
//  .speaking, .error(String) — matches your actual enum.
//

import SwiftUI
import simd

struct StellaPlasmaOrb: View {

    let state: VoiceConversationManager.State
    let spectrum: AudioSpectrum


    // Crossfade bookkeeping — see the `.onChange(of: state)` handler.
    @State private var blendStart = StellaPlasmaOrb.profile(for: .loading)
    @State private var transitionStartTime: TimeInterval = 0

    // Tunables.
    private let strandCount = 9
    private let stepsPerStrand = 72
    private let chunkCount = 6
    private let tiltAngle = 0.42            // fixed 3/4-view tilt
    private let transitionDuration: TimeInterval = 0.9

    var body: some View {

        TimelineView(.animation) { timeline in

            let time = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                draw(context: context, size: size, time: time)
            }
        }
        .frame(width: 220, height: 220)
        .onChange(of: state) { oldValue, _ in
            // Freeze wherever the crossfade currently is (not just the old
            // target) as the new starting point, so a state change that
            // arrives mid-transition doesn't jump.
            let now = Date().timeIntervalSinceReferenceDate
            let elapsed = now - transitionStartTime
            let t = transitionDuration > 0 ? min(1, max(0, elapsed / transitionDuration)) : 1
            blendStart = blend(blendStart, Self.profile(for: oldValue), smoothstep01(t))
            transitionStartTime = now
        }
    
    }

    // MARK: - Per-state motion & color profile

    private struct OrbProfile {
        var turbulence: Double
        var flowSpeed: Double       // speed of the traveling wave along each band
        var radiusScale: CGFloat
        var hueLow: Double
        var hueHigh: Double
        var hueDrift: Double
        var saturation: Double
        var brightness: Double
        var breathing: Double       // 0...1, continuous so it can crossfade
        var ringPulse: Double       // 0...1, continuous so it can crossfade
        var glowHue: Double
        var glowSaturation: Double
        var glowBrightness: Double
    }

    private static func profile(for state: VoiceConversationManager.State) -> OrbProfile {
        switch state {

        case .loading:
            return OrbProfile(
                turbulence: 0.12, flowSpeed: 0.05, radiusScale: 0.85,
                hueLow: 0.60, hueHigh: 0.66, hueDrift: 0,
                saturation: 0.32, brightness: 0.42,
                breathing: 1, ringPulse: 0,
                glowHue: 0.62, glowSaturation: 0.28, glowBrightness: 0.38
            )

        case .idle:
            return OrbProfile(
                turbulence: 0.30, flowSpeed: 0.18, radiusScale: 1.0,
                hueLow: 0.72, hueHigh: 0.82, hueDrift: 0,
                saturation: 0.55, brightness: 0.75,
                breathing: 1, ringPulse: 0,
                glowHue: 0.75, glowSaturation: 0.50, glowBrightness: 0.60
            )

        case .greeting:
            return OrbProfile(
                turbulence: 0.55, flowSpeed: 0.50, radiusScale: 1.0,
                hueLow: 0.04, hueHigh: 0.14, hueDrift: 0,
                saturation: 0.85, brightness: 0.95,
                breathing: 0, ringPulse: 1,
                glowHue: 0.08, glowSaturation: 0.60, glowBrightness: 0.75
            )

        case .listening:
            return OrbProfile(
                turbulence: 0.60, flowSpeed: 0.55, radiusScale: 1.0,
                hueLow: 0.85, hueHigh: 1.05, hueDrift: 0,
                saturation: 0.85, brightness: 0.95,
                breathing: 0, ringPulse: 1,
                glowHue: 0.92, glowSaturation: 0.60, glowBrightness: 0.75
            )

        case .transcribing:
            return OrbProfile(
                turbulence: 0.80, flowSpeed: 0.80, radiusScale: 0.90,
                hueLow: 0.58, hueHigh: 0.78, hueDrift: 0,
                saturation: 0.80, brightness: 0.90,
                breathing: 0, ringPulse: 0,
                glowHue: 0.65, glowSaturation: 0.55, glowBrightness: 0.65
            )

        case .thinking:
            return OrbProfile(
                turbulence: 0.50, flowSpeed: 1.30, radiusScale: 1.0,
                hueLow: 0.0, hueHigh: 1.0, hueDrift: 0.15,
                saturation: 0.75, brightness: 0.90,
                breathing: 0, ringPulse: 0,
                glowHue: 0.80, glowSaturation: 0.50, glowBrightness: 0.70
            )

        case .speaking:
            return OrbProfile(
                turbulence: 0.65, flowSpeed: 0.60, radiusScale: 1.0,
                hueLow: 0.02, hueHigh: 0.12, hueDrift: 0,
                saturation: 0.90, brightness: 1.0,
                breathing: 0, ringPulse: 1,
                glowHue: 0.06, glowSaturation: 0.65, glowBrightness: 0.80
            )

        case .error:
            return OrbProfile(
                turbulence: 0.12, flowSpeed: 0.08, radiusScale: 0.92,
                hueLow: 0.0, hueHigh: 0.02, hueDrift: 0,
                saturation: 0.70, brightness: 0.55,
                breathing: 1, ringPulse: 0,
                glowHue: 0.02, glowSaturation: 0.70, glowBrightness: 0.50
            )
        }
    }

    // MARK: - Crossfade helpers

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    /// Lerp across the shorter direction around the hue wheel, so a hue
    /// transition never takes the "long way round" through the spectrum.
    private func lerpHue(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var diff = b - a
        if diff > 0.5 { diff -= 1 }
        if diff < -0.5 { diff += 1 }
        var result = a + diff * t
        result = result.truncatingRemainder(dividingBy: 1)
        if result < 0 { result += 1 }
        return result
    }

    private func blend(_ a: OrbProfile, _ b: OrbProfile, _ t: Double) -> OrbProfile {
        OrbProfile(
            turbulence: lerp(a.turbulence, b.turbulence, t),
            flowSpeed: lerp(a.flowSpeed, b.flowSpeed, t),
            radiusScale: CGFloat(lerp(Double(a.radiusScale), Double(b.radiusScale), t)),
            hueLow: lerpHue(a.hueLow, b.hueLow, t),
            hueHigh: lerpHue(a.hueHigh, b.hueHigh, t),
            hueDrift: lerp(a.hueDrift, b.hueDrift, t),
            saturation: lerp(a.saturation, b.saturation, t),
            brightness: lerp(a.brightness, b.brightness, t),
            breathing: lerp(a.breathing, b.breathing, t),
            ringPulse: lerp(a.ringPulse, b.ringPulse, t),
            glowHue: lerpHue(a.glowHue, b.glowHue, t),
            glowSaturation: lerp(a.glowSaturation, b.glowSaturation, t),
            glowBrightness: lerp(a.glowBrightness, b.glowBrightness, t)
        )
    }

    private func smoothstep01(_ t: Double) -> Double {
        let c = min(1, max(0, t))
        return c * c * (3 - 2 * c)
    }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    // MARK: - Drawing

    private func draw(context: GraphicsContext, size: CGSize, time: TimeInterval) {

        let target = Self.profile(for: state)
        let elapsed = time - transitionStartTime
        let t = transitionDuration > 0 ? min(1, max(0, elapsed / transitionDuration)) : 1
        let profile = blend(blendStart, target, smoothstep01(t))

        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        let breathOsc = sin(time * 0.5) * profile.breathing
        let breathingScale: CGFloat = 1 + 0.015 * CGFloat(breathOsc)
        let bass = CGFloat(spectrum.bass)
        let mids = CGFloat(spectrum.mid)
        let highs = CGFloat(spectrum.high)
        let overall = CGFloat(spectrum.level)

        // Combine overall loudness with the FFT bands.
        //
        // This is THE value that decides whether Stella is moving.
        // Silence ≈ 0
        // Speech  ≈ 0.1 ... 1
        let rawActivity =
            overall * 0.50 +
            bass * 0.20 +
            mids * 0.22 +
            highs * 0.08

        // Noise gate.
        //
        // Tiny microphone noise should not keep Stella moving.
        let noiseFloor: CGFloat = 0.055

        let gatedActivity: CGFloat

        if rawActivity <= noiseFloor {
            gatedActivity = 0
        } else {
            gatedActivity = min(
                1,
                (rawActivity - noiseFloor) /
                    (1 - noiseFloor)
            )
        }

        // Give quiet speech enough visual presence without making
        // loud speech ridiculously violent.
        let audioActivity =
            CGFloat(
                pow(
                    Double(gatedActivity),
                    0.72
                )
            )

        let isSilent =
            audioActivity < 0.015
        
        let audioScale: CGFloat =
            1 +
            audioActivity * 0.055 +
            bass * 0.045

        let radius = min(size.width, size.height) * 0.31
            * profile.radiusScale * breathingScale * audioScale

        let sphereRect = CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        )

        let glowTint =
            Color(
                red: 0.68,
                green: 0.12,
                blue: 1.00
            )

        // -------------------------
        // Ambient bloom
        // -------------------------
        var glowContext = context
        glowContext.addFilter(.blur(radius: 22))
        glowContext.opacity =
            0.22 +
            Double(audioActivity) * 0.48
        glowContext.fill(
            Path(ellipseIn: sphereRect.insetBy(dx: -8, dy: -8)),
            with: .radialGradient(
                Gradient(colors: [glowTint.opacity(0.6), glowTint.opacity(0.25), .clear]),
                center: center, startRadius: radius * 0.3, endRadius: radius * 1.35
            )
        )

        // -------------------------
        // Dark glass sphere
        // -------------------------
        context.fill(
            Path(ellipseIn: sphereRect),
            with: .radialGradient(
                Gradient(colors: [
                    Color.purple.opacity(0.10),
                    Color.black.opacity(0.40),
                    Color.black.opacity(0.72)
                ]),
                center: CGPoint(x: center.x - radius * 0.3, y: center.y - radius * 0.3),
                startRadius: 0, endRadius: radius
            )
        )

        var sphereContext = context
        sphereContext.clip(to: Path(ellipseIn: sphereRect))

        // -------------------------
        // Flowing plasma bands
        // -------------------------
        // Gentle side-to-side sway replaces the old continuous spin — the
        // structure doesn't keep rotating in one direction, it just breathes
        // a little. All the "movement" you actually perceive should come
        // from the traveling wave inside the loop below.
        // No constant spinning/waving.
        //
        // Silence = almost completely stationary.
        //
        // Audio activity controls how quickly waves travel.
        let restingMotion: Double =
            isSilent ? 0.0 : 0.025

        let movementStrength =
            Double(audioActivity)

        let dynamicFlowSpeed =
            0.15 +
            movementStrength * 5.0

        let travel =
            time *
            dynamicFlowSpeed *
            max(
                restingMotion,
                movementStrength
            )

        // Very small spatial sway when speaking.
        // Absolutely no continuous sway in silence.
        let swayAngle =
            sin(time * 0.75) *
            0.10 *
            movementStrength

        for index in 0..<strandCount {

            let axis = bandAxis(index: index, total: strandCount)
            let (u, v) = orthonormalBasis(around: axis)

            let indexD = Double(index)
            let phase = indexD * 2.399  // golden-angle-ish spread, avoids sync'd repeats
            let freqMain = 2.0 + Double(index % 3) * 0.4
            let freqSecondary = 5.0 + Double((index + 1) % 4) * 0.3

            var points: [(pt: CGPoint, z: Double)] = []
            points.reserveCapacity(stepsPerStrand + 1)

            for step in 0...stepsPerStrand {
                let theta = (Double(step) / Double(stepsPerStrand)) * 2 * Double.pi

                // Traveling wave: crests move around the loop over time
                // (phase term uses `travel`, not a static offset), which is
                // what reads as flowing/ocean-like rather than rotating.
                let activity =
                    Double(audioActivity)

                // Broad organic deformation.
                // Almost nothing without voice.
                let waveMain =
                    sin(
                        theta * freqMain -
                        travel * 1.3 +
                        phase
                    )
                    * 0.18
                    * activity

                // Smaller secondary ripples.
                let waveSecondary =
                    sin(
                        theta * freqSecondary +
                        travel * 1.9 -
                        phase * 1.4
                    )
                    * 0.075
                    * activity
                // Bass produces large, slow displacement.
                let bassWave =
                    Double(spectrum.bass)
                    *
                    sin(
                        theta * 2.0 -
                        travel * 0.85 +
                        phase
                    )
                    * 0.20

                // Voice frequencies provide most of Stella's
                // visible fluid motion.
                let midWave =
                    Double(spectrum.mid)
                    *
                    sin(
                        theta * 6.5 -
                        travel * 2.2 +
                        phase * 1.3
                    )
                    * 0.24

                // High frequencies create smaller,
                // quicker surface ripples.
                let highWave =
                    Double(spectrum.high)
                    *
                    sin(
                        theta * 15.0 -
                        travel * 4.7 -
                        phase
                    )
                    * 0.105

                let audioWave =
                    bassWave +
                    midWave +
                    highWave
                let r =
                    1 +
                    waveMain +
                    waveSecondary +
                    audioWave

                var point = (u * cos(theta) + v * sin(theta)) * r
                point = rotateAroundX(point, angle: tiltAngle)
                point = rotateAroundY(point, angle: swayAngle)

                let screenPoint = CGPoint(
                    x: center.x + CGFloat(point.x) * radius,
                    y: center.y + CGFloat(point.y) * radius
                )
                points.append((screenPoint, point.z))
            }

            let fraction = indexD / Double(strandCount)
            let strandColor =
                plasmaColor(
                    index: index
                )

            // Fixed number of chunks per band (not data-dependent), so depth
            // shading is always a smooth, stable gradient rather than a
            // variable number of jagged sub-paths.
            let chunkSize = stepsPerStrand / chunkCount
            for chunk in 0..<chunkCount {
                let start = chunk * chunkSize
                let end = (chunk == chunkCount - 1) ? stepsPerStrand : (chunk + 1) * chunkSize
                guard end > start else { continue }

                var path = Path()
                var zSum = 0.0
                for i in start...end {
                    let sample = points[i]
                    if i == start {
                        path.move(to: sample.pt)
                    } else {
                        path.addLine(to: sample.pt)
                    }
                    zSum += sample.z
                }
                let avgZ = zSum / Double(end - start + 1)
                let depthAlpha = smoothstep(-0.6, 0.5, avgZ)   // 0 = far back, 1 = front

                let chunkColor =
                    strandColor
                        .opacity(
                            0.72 +
                            depthAlpha * 0.28
                        )

                let baseAlpha = 0.22 + depthAlpha * 0.78

                var glow = sphereContext
                glow.blendMode = .plusLighter
                glow.addFilter(.blur(radius: 5))
                glow.opacity =
                    (
                        0.50 +
                        Double(spectrum.level) * 0.15 +
                        Double(spectrum.high) * 0.30
                    )
                    * baseAlpha

                let glowWidth =
                    CGFloat(4)
                    +
                    mids * 2.4
                    +
                    bass * 1.2
                glow.stroke(
                    path,
                    with: .color(chunkColor),
                    lineWidth: glowWidth
                )

                let sharpWidth =
                    CGFloat(1.1)
                    +
                    highs * 1.0
                    +
                    mids * 0.5

                var sharp = sphereContext
                sharp.blendMode = .plusLighter
                sharp.opacity = 0.85 * baseAlpha
                sharp.stroke(
                    path,
                    with: .color(chunkColor),
                    lineWidth: sharpWidth
                )
            }
        }

        // -------------------------
        // Outward rhythmic ring (speaking / listening / greeting)
        // -------------------------
        if audioActivity > 0.10 {
            let pulseT = (time * 0.9).truncatingRemainder(dividingBy: 1.0)
            let ringRadius = radius * (1.05 + pulseT * 0.55)
            let ringAlpha =
                (1 - pulseT)
                *
                Double(audioActivity)
                *
                0.38

            var ring = context
            ring.blendMode = .plusLighter
            ring.opacity = ringAlpha
            ring.stroke(
                Path(ellipseIn: CGRect(
                    x: center.x - ringRadius, y: center.y - ringRadius,
                    width: ringRadius * 2, height: ringRadius * 2
                )),
                with: .color(glowTint),
                lineWidth: 2
            )
        }
    }

    // MARK: - 3D helpers

    /// All bands are rotations of the same base axis (screen-facing Z)
    /// around the shared X axis, fanned across a limited angular range.
    /// That keeps every band's loop plane part of one coherent family
    /// (think latitude lines at different tilts) instead of independently
    /// oriented loops, which is what previously read as a tangled scramble.
    private func bandAxis(index: Int, total: Int) -> SIMD3<Double> {
        let fraction = (Double(index) + 0.5) / Double(total) - 0.5   // -0.5...0.5
        let fanAngle = fraction * Double.pi * 0.85                    // ~±76°
        return normalize(rotateAroundX(SIMD3<Double>(0, 0, 1), angle: fanAngle))
    }

    private func orthonormalBasis(around axis: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        let helper: SIMD3<Double> = abs(axis.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let u = normalize(cross(helper, axis))
        let v = cross(axis, u)
        return (u, v)
    }

    private func rotateAroundX(_ p: SIMD3<Double>, angle: Double) -> SIMD3<Double> {
        let c = cos(angle), s = sin(angle)
        return SIMD3(p.x, p.y * c - p.z * s, p.y * s + p.z * c)
    }

    private func rotateAroundY(_ p: SIMD3<Double>, angle: Double) -> SIMD3<Double> {
        let c = cos(angle), s = sin(angle)
        return SIMD3(p.x * c + p.z * s, p.y, -p.x * s + p.z * c)
    }
    private func plasmaColor(
        index: Int
    ) -> Color {

        let palette: [Color] = [

            // Magenta
            Color(
                red: 1.00,
                green: 0.05,
                blue: 0.62
            ),

            // Red
            Color(
                red: 1.00,
                green: 0.08,
                blue: 0.12
            ),

            // Royal blue
            Color(
                red: 0.18,
                green: 0.30,
                blue: 1.00
            ),

            // Purple
            Color(
                red: 0.62,
                green: 0.16,
                blue: 1.00
            )
        ]

        return palette[
            index % palette.count
        ]
    }
}
