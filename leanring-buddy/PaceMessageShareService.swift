//
//  PaceMessageShareService.swift
//  leanring-buddy
//
//  Thin wrapper over `NSSharingServicePicker` that lets users share a
//  Pace assistant reply through any of the system's installed share
//  destinations — Messages, Mail, Notes, AirDrop, Reminders, third-
//  party apps that register sharing services, etc.
//
//  The whole point is that we don't have to build per-destination
//  integrations. macOS already knows where the user wants to send
//  text and which extensions to surface; we just hand it the text
//  and an anchor view.
//

import AppKit
import Foundation

@MainActor
enum PaceMessageShareService {

    /// Present the system share sheet anchored to `anchorView`. The
    /// anchor edge defaults to `.minY` so the picker drops below the
    /// triggering control, matching the convention every other macOS
    /// share button uses.
    ///
    /// Empty / whitespace-only text is a no-op — the share sheet
    /// would otherwise pop up with nothing meaningful for the user
    /// to send.
    static func presentSharePicker(
        forText messageText: String,
        anchoredTo anchorView: NSView,
        preferredEdge: NSRectEdge = .minY
    ) {
        let trimmedText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        let sharingItems: [Any] = [trimmedText]
        let sharingPicker = NSSharingServicePicker(items: sharingItems)
        sharingPicker.show(
            relativeTo: anchorView.bounds,
            of: anchorView,
            preferredEdge: preferredEdge
        )
    }
}
