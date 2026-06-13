//
//  PaceTurnHUDView.swift
//  leanring-buddy
//
//  Notch-panel turn HUD card. Renders the current PaceTurnHUDState
//  (listening / understanding / acting / needs-clarification / done /
//  failed / unsupported) with its symbol, title, optional detail line,
//  and — for clarification — the inline option chips that route back
//  through `CompanionManager.resolveClarification(option:)`.
//
//  Extracted from CompanionPanelView.swift verbatim; the icon + color
//  helpers move with it because they ONLY drive the HUD card.
//

import SwiftUI

struct PaceTurnHUDView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: turnHUDSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(turnHUDColor)
                .frame(width: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(companionManager.currentTurnHUDState.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let detail = companionManager.currentTurnHUDState.detail,
                   !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if companionManager.currentTurnHUDState.status == .needsClarification,
                   !companionManager.currentTurnHUDState.options.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(companionManager.currentTurnHUDState.options, id: \.self) { option in
                            Button(action: {
                                companionManager.resolveClarification(option: option)
                            }) {
                                Text(option)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(Color.white.opacity(0.07))
                                    )
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                        }
                    }
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }

    private var turnHUDSymbol: String {
        switch companionManager.currentTurnHUDState.status {
        case .idle:
            return "checkmark.circle"
        case .listening:
            return "waveform"
        case .understanding:
            return "magnifyingglass"
        case .acting:
            return "cursorarrow"
        case .needsClarification:
            return "questionmark.circle"
        case .done:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle"
        case .unsupported:
            return "lock.shield"
        }
    }

    private var turnHUDColor: Color {
        switch companionManager.currentTurnHUDState.status {
        case .idle:
            return DS.Colors.textTertiary
        case .listening, .understanding, .acting:
            return DS.Colors.accent
        case .needsClarification:
            return DS.Colors.warning
        case .done:
            return DS.Colors.success
        case .failed, .unsupported:
            return DS.Colors.warning
        }
    }
}
