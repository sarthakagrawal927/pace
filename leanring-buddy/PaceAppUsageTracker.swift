//
//  PaceAppUsageTracker.swift
//  leanring-buddy
//
//  Thin AppKit glue between NSWorkspace app-activation notifications and
//  the pure PaceAppUsageJournal. Flushes the journal into retrieval on
//  every app switch plus a periodic timer so long single-app stretches
//  still land in the index. All accounting logic lives in the journal,
//  which is what the unit tests cover.
//

import AppKit

@MainActor
final class PaceAppUsageTracker {
    static let periodicFlushIntervalInSeconds: TimeInterval = 300

    private var journal: PaceAppUsageJournal
    private let onFlushedDocument: (PaceRetrievalDocument) -> Void
    private var activationObserver: NSObjectProtocol?
    private var periodicFlushTimer: Timer?
    private(set) var isRunning = false

    init(
        rehydratedJournal: PaceAppUsageJournal,
        onFlushedDocument: @escaping (PaceRetrievalDocument) -> Void
    ) {
        self.journal = rehydratedJournal
        self.onFlushedDocument = onFlushedDocument
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        if let frontmostApplicationName = NSWorkspace.shared.frontmostApplication?.localizedName {
            journal.recordActivation(appName: frontmostApplicationName, at: Date())
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedApplication = notification
                .userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let activatedApplicationName = activatedApplication?.localizedName
            Task { @MainActor [weak self] in
                self?.handleApplicationActivated(named: activatedApplicationName)
            }
        }

        let flushTimer = Timer(
            timeInterval: Self.periodicFlushIntervalInSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushNow()
            }
        }
        flushTimer.tolerance = 30
        RunLoop.main.add(flushTimer, forMode: .common)
        periodicFlushTimer = flushTimer
        print("⏱️ App usage tracking started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        flushNow()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        periodicFlushTimer?.invalidate()
        periodicFlushTimer = nil
        print("⏱️ App usage tracking stopped")
    }

    private func handleApplicationActivated(named applicationName: String?) {
        guard isRunning, let applicationName else { return }
        journal.recordActivation(appName: applicationName, at: Date())
        flushNow()
    }

    private func flushNow() {
        if let changedDocument = journal.flush(now: Date()) {
            onFlushedDocument(changedDocument)
        }
    }
}
