// KeyEventFixture.swift
// Weir — one builder for the key-down events the keyboard suites hand a view.

import AppKit
import Testing

extension NSEvent {
    /// A key-down of `keyCode` with `modifiers`, typing `characters` both
    /// with and without them.
    ///
    /// `keyEvent` takes ten arguments and answers an optional, so each
    /// suite had written it out and unwrapped it on its own; the ones a test
    /// is about are the key, the modifiers, and sometimes the characters.
    /// The location, context and repeat flag never vary here. Throws, through
    /// `#require`, when AppKit declines to make the event.
    static func testKeyDown(
        keyCode: UInt16,
        modifiers: ModifierFlags = [],
        characters: String = "",
        timestamp: TimeInterval = 0,
        windowNumber: Int = 0,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: timestamp,
                windowNumber: windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ),
            sourceLocation: sourceLocation
        )
    }
}
