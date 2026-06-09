//
//  PaceAnalytics.swift
//  leanring-buddy
//
//  Local-only analytics shim. Pace's product contract is no cloud telemetry,
//  so these call sites intentionally do not send data off the Mac.
//

import Foundation

enum PaceAnalytics {

    // MARK: - Setup

    static func configure() {
        // Intentionally empty: no network analytics initialization.
    }

    // MARK: - App Lifecycle

    /// Fired once on every app launch in applicationDidFinishLaunching.
    static func trackAppOpened() {
        _ = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    // MARK: - Permissions

    /// All three permissions (accessibility, screen recording, mic) are granted.
    static func trackAllPermissionsGranted() {
        // No-op: permission telemetry stays local-only.
    }

    /// A single permission was granted. Called when polling detects a change.
    static func trackPermissionGranted(permission: String) {
        _ = permission
    }

    // MARK: - Voice Interaction

    /// User pressed the push-to-talk shortcut (control+option) to start talking.
    static func trackPushToTalkStarted() {
        // No-op: interaction telemetry stays local-only.
    }

    /// User released the shortcut — transcript is being finalized.
    static func trackPushToTalkReleased() {
        // No-op: interaction telemetry stays local-only.
    }

    /// Transcription completed and the user's message is being sent to the AI.
    static func trackUserMessageSent(transcript: String) {
        _ = transcript.count
    }

    /// The local planner responded and the response is being spoken via TTS.
    static func trackAIResponseReceived(response: String) {
        _ = response.count
    }

    /// The planner response included a [POINT:x,y:label] coordinate tag,
    /// so the buddy is flying to point at a UI element.
    static func trackElementPointed(elementLabel: String?) {
        _ = elementLabel
    }

    // MARK: - Errors

    /// An error occurred during the AI response pipeline.
    static func trackResponseError(error: String) {
        _ = error
    }

}
