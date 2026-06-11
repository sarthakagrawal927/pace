//
//  PaceOnboardingView.swift
//  leanring-buddy
//
//  First-launch permission walkthrough. The whole product gate.
//
//  Design rules:
//  - Never trigger the macOS modal permission prompt (AX, Screen
//    Recording) — that prompt is a one-shot per bundle identity and
//    re-clicking does nothing helpful. We deep-link to the right
//    System Settings pane instead. The user grants once there.
//  - Auto-advance when a permission flips to granted (PacePermissionService
//    polls + active-app refresh take care of detection). No "press Next."
//  - Required permissions block progress; optional ones are skippable.
//

import AppKit
import AVFoundation
import SwiftUI

private enum PaceOnboardingStep: Int, CaseIterable, Identifiable {
    case welcome = 0
    case accessibility
    case screenRecording
    case microphone
    case done

    var id: Int { rawValue }
}

private struct PacePermissionStep {
    let kind: PacePermissionKind
    let title: String
    let why: String
    let settingsURL: URL
}

@MainActor
struct PaceOnboardingView: View {
    let onComplete: () -> Void

    @ObservedObject private var permissionService = PacePermissionService.shared
    @State private var currentStep: PaceOnboardingStep = .welcome

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 40)
                .padding(.top, 36)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
                .padding(.horizontal, 40)
                .padding(.bottom, 28)
        }
        .frame(width: 560, height: 460)
        .onChange(of: permissionService.grants) { _ in autoAdvanceIfGranted() }
    }

    // MARK: - Pages

    @ViewBuilder
    private var content: some View {
        switch currentStep {
        case .welcome:
            welcomePage
        case .accessibility:
            permissionPage(step: Self.accessibilityStep)
        case .screenRecording:
            permissionPage(step: Self.screenRecordingStep)
        case .microphone:
            microphonePage
        case .done:
            donePage
        }
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hi, I'm Pace.")
                .font(.system(size: 28, weight: .semibold))
            Text("A voice companion that runs entirely on your Mac. No cloud models, no logging, no telemetry.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Spacer().frame(height: 8)
            Text("I need three macOS permissions to be useful. Each one opens System Settings — you toggle me on, switch back, I auto-detect it.")
                .font(.system(size: 14))
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionPage(step: PacePermissionStep) -> some View {
        let isGranted = permissionService.isGranted(step.kind)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: isGranted ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isGranted ? .green : .secondary)
                    .font(.system(size: 22))
                Text(step.title)
                    .font(.system(size: 22, weight: .semibold))
            }
            Text(step.why)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer().frame(height: 8)
            if isGranted {
                Text("Granted. Moving on…")
                    .foregroundColor(.green)
                    .font(.system(size: 13, weight: .medium))
            } else {
                Button(action: { NSWorkspace.shared.open(step.settingsURL) }) {
                    Label("Open System Settings", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                Text("Toggle Pace on, then come back here — I'll detect it within a few seconds.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var microphonePage: some View {
        let isGranted = permissionService.isGranted(.microphone)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: isGranted ? "checkmark.circle.fill" : "mic.circle")
                    .foregroundColor(isGranted ? .green : .secondary)
                    .font(.system(size: 22))
                Text("Microphone")
                    .font(.system(size: 22, weight: .semibold))
            }
            Text("So I can hear push-to-talk. Audio stays local — speech recognition runs on your Mac.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer().frame(height: 8)
            if isGranted {
                Text("Granted. Moving on…")
                    .foregroundColor(.green)
                    .font(.system(size: 13, weight: .medium))
            } else {
                Button(action: requestMicrophone) {
                    Label("Allow microphone", systemImage: "mic")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                Text("macOS will show a one-time prompt — this is the only system prompt during onboarding.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var donePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 22))
                Text("All set.")
                    .font(.system(size: 22, weight: .semibold))
            }
            Text("Try it: hold control + option and ask me something. I'm in your menu bar — the small black capsule near the notch.")
                .font(.system(size: 14))
            Text("Optional permissions (Calendar, Reminders, Contacts, Camera for posture) can be granted later from the Permissions tab when you ask me to use them.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if currentStep != .welcome && currentStep != .done {
                Button("Skip for now") { advance() }
                    .buttonStyle(.borderless)
            }
            Spacer()
            stepIndicator
            Spacer()
            Button(footerActionLabel) {
                if currentStep == .done {
                    finish()
                } else {
                    advance()
                }
            }
            .keyboardShortcut(.return)
            .buttonStyle(.borderedProminent)
            .disabled(footerActionDisabled)
        }
    }

    private var footerActionLabel: String {
        switch currentStep {
        case .welcome: return "Get started"
        case .done: return "Finish"
        default: return permissionService.isGranted(currentStepPermissionKind ?? .microphone) ? "Next" : "Skip"
        }
    }

    private var footerActionDisabled: Bool { false }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(PaceOnboardingStep.allCases) { step in
                Circle()
                    .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var currentStepPermissionKind: PacePermissionKind? {
        switch currentStep {
        case .accessibility: return .accessibility
        case .screenRecording: return .screenRecording
        case .microphone: return .microphone
        default: return nil
        }
    }

    // MARK: - Navigation

    private func advance() {
        guard let nextStep = PaceOnboardingStep(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = nextStep
    }

    private func autoAdvanceIfGranted() {
        guard let kind = currentStepPermissionKind, permissionService.isGranted(kind) else { return }
        // Tiny delay so the user sees the green "granted" state before
        // the page changes.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            advance()
        }
    }

    private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in PacePermissionService.shared.refresh() }
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        onComplete()
    }

    // MARK: - Step definitions

    private static let accessibilityStep = PacePermissionStep(
        kind: .accessibility,
        title: "Accessibility",
        why: "I listen for control + option as your push-to-talk shortcut and click UI elements when you ask me to. Both need Accessibility.",
        settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    )

    private static let screenRecordingStep = PacePermissionStep(
        kind: .screenRecording,
        title: "Screen Recording",
        why: "When you ask me about what's on screen, I take a screenshot, analyze it on-device, and discard it. Nothing is recorded or stored.",
        settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    )
}
