//
//  TTSEngine.swift
//  Stella
//
//  Created by Harish Maheshwaran on 31/08/26.
//


//
//  TTSEngine.swift
//  Stella
//

import AVFoundation

protocol TTSEngine: AnyObject {

    var name: String { get }

    var isSpeaking: Bool { get }

    func prepare() async throws

    func speak(
        _ text: String,
        onSpectrum: @escaping (AudioSpectrum) -> Void,
        onFinished: @escaping () -> Void
    )

    func stop()
}