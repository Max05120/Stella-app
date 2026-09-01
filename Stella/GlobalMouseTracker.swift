//
//  GlobalMouseTracker.swift
//  Stella
//
//  Created by Harish Maheshwaran on 01/09/26.
//


import AppKit
import Combine

@MainActor
final class GlobalMouseTracker: ObservableObject {

    @Published var globalPosition: CGPoint = .zero

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }

        timer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 60.0,
            repeats: true
        ) { [weak self] _ in

            Task { @MainActor in
                self?.globalPosition = NSEvent.mouseLocation
            }
        }

        RunLoop.main.add(
            timer!,
            forMode: .common
        )
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}