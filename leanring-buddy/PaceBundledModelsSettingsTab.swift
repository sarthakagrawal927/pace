//
//  PaceBundledModelsSettingsTab.swift
//  leanring-buddy
//
//  Settings → Models tab. Toggles + model identifiers for the
//  in-process MLX runtime. Default state is OFF — existing users
//  must explicitly opt in. The runtime-status row at the top
//  surfaces whether the `mlx-swift-examples` SPM dependency is
//  actually linked, so users aren't left guessing.
//
//  First inference call after enabling the toggle triggers a one-
//  time HuggingFace download via the Hub package built into
//  mlx-swift-examples (~2-3 GB for the 4B planner, ~250 MB for the
//  nomic embedder). No progress UI in this view — the download is
//  blocking on the first turn, and the panel HUD's "thinking…"
//  state already covers that wait visually.
//

import AppKit
import SwiftUI

struct PaceBundledModelsSettingsTab: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var isUsingMLXPlanner: Bool = false
    @State private var isUsingMLXEmbedder: Bool = false
    @State private var plannerModelIdentifier: String = ""
    @State private var embedderModelIdentifier: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            runtimeStatusSection
            Divider().background(DS.Colors.borderSubtle)
            plannerSection
            Divider().background(DS.Colors.borderSubtle)
            embedderSection
            Divider().background(DS.Colors.borderSubtle)
            qualityCaveatSection
        }
        .onAppear(perform: loadCurrentSettings)
    }

    // MARK: - Runtime status

    private var runtimeStatusSection: some View {
        let plannerLinked = PaceMLXPlannerClient.isRuntimeAvailable
        let embedderLinked = PaceMLXEmbeddingClient.isRuntimeAvailable
        let summaryText = PaceBundledModelsSettings.runtimeStatusSummary(
            plannerRuntimeAvailable: plannerLinked,
            embedderRuntimeAvailable: embedderLinked
        )
        let isHealthy = plannerLinked && embedderLinked
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(isHealthy ? .green : .yellow)
                .font(.system(size: 14))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("MLX Runtime")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(summaryText)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    // MARK: - Planner section

    private var plannerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isUsingMLXPlanner) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("In-process MLX planner")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Run the planner via mlx-swift in-process. Drops the LM Studio install dependency for new users. Quality is lower than qwen3-30b-a3b — opt in when you don't need the bigger model.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!PaceMLXPlannerClient.isRuntimeAvailable)
            .onChange(of: isUsingMLXPlanner) { _, newValue in
                PaceBundledModelsSettings.setUsingMLXInProcessPlanner(newValue)
            }
            HStack(spacing: 8) {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                TextField(
                    "mlx-community/Qwen3-4B-Instruct-4bit",
                    text: $plannerModelIdentifier
                )
                .textFieldStyle(.roundedBorder)
                .disabled(!isUsingMLXPlanner)
                .onSubmit { commitPlannerModelIdentifier() }
                Button("Apply") { commitPlannerModelIdentifier() }
                    .buttonStyle(.bordered)
                    .disabled(!isUsingMLXPlanner)
            }
            Text("On first use, ~2-3 GB is downloaded into the HuggingFace cache (~/.cache/huggingface). Subsequent launches load from cache.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Embedder section

    private var embedderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $isUsingMLXEmbedder) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("In-process MLX embedder")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Run semantic-memory embeddings via mlx-swift in-process. Falls back to Apple NaturalLanguage when the model isn't downloaded yet — safe to flip on.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!PaceMLXEmbeddingClient.isRuntimeAvailable)
            .onChange(of: isUsingMLXEmbedder) { _, newValue in
                PaceBundledModelsSettings.setUsingMLXInProcessEmbedder(newValue)
            }
            HStack(spacing: 8) {
                Text("Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                TextField(
                    "nomic-ai/nomic-embed-text-v1.5",
                    text: $embedderModelIdentifier
                )
                .textFieldStyle(.roundedBorder)
                .disabled(!isUsingMLXEmbedder)
                .onSubmit { commitEmbedderModelIdentifier() }
                Button("Apply") { commitEmbedderModelIdentifier() }
                    .buttonStyle(.bordered)
                    .disabled(!isUsingMLXEmbedder)
            }
            Text("~250 MB download on first use. Lower recall than LM Studio's nomic model but works offline with zero install steps.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Quality caveat

    private var qualityCaveatSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quality notes")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text("Bundled MLX is the right choice when you don't have LM Studio installed and don't want to install it. The 4B planner scores ~3-4 points below qwen3-30b-a3b on Pace's FM-fixture eval set, mostly affecting multi-step agent reasoning. For day-to-day voice turns the gap is small. The embedder is a cleaner swap — Apple NaturalLanguage fallback keeps recall working when the MLX model isn't loaded yet.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Settings IO

    private func loadCurrentSettings() {
        isUsingMLXPlanner = PaceBundledModelsSettings.isUsingMLXInProcessPlanner()
        isUsingMLXEmbedder = PaceBundledModelsSettings.isUsingMLXInProcessEmbedder()
        plannerModelIdentifier = PaceBundledModelsSettings.plannerModelIdentifier()
        embedderModelIdentifier = PaceBundledModelsSettings.embedderModelIdentifier()
    }

    private func commitPlannerModelIdentifier() {
        PaceBundledModelsSettings.setPlannerModelIdentifier(plannerModelIdentifier)
        // Reload in case the setter refused an empty/whitespace value
        // — keeps the field in sync with what was actually persisted.
        plannerModelIdentifier = PaceBundledModelsSettings.plannerModelIdentifier()
    }

    private func commitEmbedderModelIdentifier() {
        PaceBundledModelsSettings.setEmbedderModelIdentifier(embedderModelIdentifier)
        embedderModelIdentifier = PaceBundledModelsSettings.embedderModelIdentifier()
    }
}
