//
//  PaceDoctorSettingsTab.swift
//  leanring-buddy
//
//  Settings → Diagnostics tab. Runs PaceLocalStackDoctor on appear and
//  on demand, then renders one row per check with a status glyph, detail
//  text, and an optional fix hint. Read-only — no mutations.
//

import SwiftUI

struct PaceDoctorSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var checks: [PaceDoctorCheck] = []
    @State private var isRunning: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Local stack diagnostics")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("Probes LM Studio, the planner model, the embedding model, the VLM, and the TTS sidecar. Use this when Pace is misbehaving and you're not sure what's offline — it tells you exactly what's broken and how to fix it.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                paceSettingsButton(
                    isRunning ? "Checking…" : "Run checks",
                    systemName: isRunning ? "arrow.triangle.2.circlepath" : "stethoscope"
                ) {
                    Task { await runDoctorChecks() }
                }
                .disabled(isRunning)

                if !checks.isEmpty && !isRunning {
                    Text("Last checked just now")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            if !checks.isEmpty {
                Divider()
                    .background(DS.Colors.borderSubtle)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(checks) { check in
                        doctorCheckRow(check)
                    }
                }
            } else if !isRunning {
                Text("Tap \"Run checks\" to probe the local stack.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .onAppear {
            Task { await runDoctorChecks() }
        }
    }

    // MARK: - Check Row

    private func doctorCheckRow(_ check: PaceDoctorCheck) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                statusGlyph(for: check.status)
                    .frame(width: 18, alignment: .center)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(check.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(check.detail)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let fixHint = check.fixHint {
                        Text(fixHint)
                            .font(.system(size: 11))
                            .foregroundColor(fixHintColor(for: check.status))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(.top, 2)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor(for: check.status), lineWidth: 0.7)
        )
    }

    // MARK: - Visual Helpers

    @ViewBuilder
    private func statusGlyph(for status: PaceDoctorStatus) -> some View {
        switch status {
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(DS.Colors.success)
        case .warn:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(DS.Colors.warning)
        case .fail:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.red)
        }
    }

    private func borderColor(for status: PaceDoctorStatus) -> Color {
        switch status {
        case .ok:
            return DS.Colors.borderSubtle
        case .warn:
            return DS.Colors.warning.opacity(0.35)
        case .fail:
            return Color.red.opacity(0.35)
        }
    }

    private func fixHintColor(for status: PaceDoctorStatus) -> Color {
        switch status {
        case .ok:
            return DS.Colors.textTertiary
        case .warn:
            return DS.Colors.warning
        case .fail:
            return DS.Colors.warning
        }
    }

    // MARK: - Action

    private func runDoctorChecks() async {
        isRunning = true
        let doctor = PaceLocalStackDoctor()
        checks = await doctor.runChecks()
        isRunning = false
    }
}
