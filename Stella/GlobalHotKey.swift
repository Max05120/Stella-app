//
//  GlobalHotKey.swift
//  Stella
//
//  Created by Harish Maheshwaran on 29/08/26.
//


import Carbon

final class GlobalHotKey {

    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32
    private static var registry: [UInt32: GlobalHotKey] = [:]

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.id = UInt32(Self.registry.count + 1)
        self.action = action
        Self.registry[id] = self
        register(keyCode: keyCode, modifiers: modifiers)
    }

    private let action: () -> Void

    private func register(keyCode: UInt32, modifiers: UInt32) {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(GetApplicationEventTarget(), { (_, eventRef, _) -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(eventRef, EventParamName(kEventParamDirectObject),
                               EventParamType(typeEventHotKeyID), nil,
                               MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            GlobalHotKey.registry[hotKeyID.id]?.action()
            return noErr
        }, 1, &eventType, nil, nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x53544C41), id: id)  // 'STLA'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        Self.registry[id] = nil
    }
}