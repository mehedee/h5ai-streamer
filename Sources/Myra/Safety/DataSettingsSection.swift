import SwiftUI

/// Settings > Data: the safety net (daily backups, Back Up Now), restore points with a confirmed
/// restore and Undo, and the Storage view with one-click cleanup of regenerable caches only.
struct DataSettingsSection: View {
  @ObservedObject var backups: LibraryBackupService

  @State private var confirmRestore: BackupRecord?
  @State private var confirmCleanup = false

  private var restorePresented: Binding<Bool> {
    Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } })
  }

  var body: some View {
    SettingsGroup(
      title: "Safety net",
      note:
        "Backups keep the watchlist, watched state, ratings, notes, collections and preferences, with a copy of the library index. They never touch your media files."
    ) {
      SettingsToggleRow(
        title: "Back up daily", detail: "Runs once a day while Myra is open",
        isOn: Binding(get: { backups.dailyEnabled }, set: { backups.dailyEnabled = $0 }))
      SettingsRow(title: "Keep", detail: "The oldest backups are removed first") {
        SettingsSelect(
          title: "Keep",
          selection: Binding(get: { backups.keep }, set: { backups.keep = $0 }),
          options: BackupRetention.keepChoices.map {
            SettingsOption(value: $0, title: "\($0) backups")
          })
      }
      SettingsRow(title: "Back up now", detail: "Saves a manual restore point") {
        Button("Back Up Now") {
          Task { await backups.backUpNow() }
        }
        .buttonStyle(MyraButtonStyle(prominent: true))
        .disabled(backups.isWorking)
      }
      if let message = backups.message {
        SettingsInlineMessage(text: message)
      }
    }
    SettingsGroup(
      title: "Restore points",
      note:
        "Restoring brings back watched state and preferences only. Your library index is not changed; it is rebuilt from your sources."
    ) {
      if backups.records.isEmpty {
        SettingsRow(title: "No restore points yet", detail: "The first daily backup runs shortly after launch.") {
          EmptyView()
        }
      }
      ForEach(backups.records.prefix(14)) { record in
        SettingsRow(
          title: record.createdAt.formatted(date: .abbreviated, time: .shortened),
          detail:
            "\(record.manifest.kind.title) · \(StorageSummary.formatted(record.bytes)) · library index not touched"
        ) {
          Button("Restore…") { confirmRestore = record }
            .buttonStyle(MyraButtonStyle())
            .disabled(!record.manifest.hasPersonal || backups.isWorking)
        }
      }
      if backups.rollbackAvailable {
        SettingsRow(title: "Undo last restore", detail: "Returns to the state kept before the restore") {
          Button("Undo") {
            Task { await backups.undoLastRestore() }
          }
          .buttonStyle(MyraButtonStyle())
          .disabled(backups.isWorking)
        }
      }
    }
    SettingsGroup(
      title: "Storage",
      note:
        "Clean up removes only regenerable caches. The library, settings, backups and credentials are kept."
    ) {
      if let storage = backups.storage {
        SettingsRow(title: "Library index", detail: "Your saved catalogue and search index") {
          Text(StorageSummary.formatted(storage.libraryIndexBytes)).monospacedDigit()
            .foregroundStyle(MyraColor.text2)
        }
        SettingsRow(title: "Backups", detail: "Restore points, newest kept") {
          Text(StorageSummary.formatted(storage.backupBytes)).monospacedDigit()
            .foregroundStyle(MyraColor.text2)
        }
        SettingsRow(title: "Artwork cache", detail: "Posters and backdrops, rebuilt as needed") {
          Text(StorageSummary.formatted(storage.artworkBytes)).monospacedDigit()
            .foregroundStyle(MyraColor.text2)
        }
        SettingsRow(
          title: "Regenerable caches",
          detail: "Home cache \(StorageSummary.formatted(storage.homeCacheBytes)) · older backups and staging files"
        ) {
          Text(StorageSummary.formatted(storage.reclaimableBytes)).monospacedDigit()
            .foregroundStyle(MyraColor.text2)
        }
        SettingsRow(
          title: "Clean up", detail: "Frees \(StorageSummary.formatted(storage.reclaimableBytes))"
        ) {
          Button("Reclaim Space…") { confirmCleanup = true }
            .buttonStyle(MyraButtonStyle(prominent: true))
            .disabled(storage.reclaimableBytes == 0 || backups.isWorking)
        }
      } else {
        SettingsRow(title: "Measuring storage…") { ProgressView().controlSize(.small) }
      }
    }
    .task {
      backups.refresh()
      await backups.refreshStorage()
    }
    .alert(
      "Restore watched state and preferences?", isPresented: restorePresented, presenting: confirmRestore
    ) { record in
      Button("Restore") {
        Task { await backups.restore(record) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { record in
      Text(
        "Your current state is kept, so you can Undo. Playback history and the library index are not changed. Backup from \(record.createdAt.formatted(date: .abbreviated, time: .shortened))."
      )
    }
    .alert("Reclaim space?", isPresented: $confirmCleanup) {
      Button("Reclaim") {
        Task { await backups.cleanUp() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Removes only regenerable caches. Your library, settings, backups and credentials are kept.")
    }
  }
}

/// Settings > Playback > Versions: the preferred resolution for titles with several releases.
struct PlaybackVersionsGroup: View {
  @ObservedObject var store: EntertainmentStore

  var body: some View {
    SettingsGroup(
      title: "Versions",
      note:
        "Used when a title exists in several qualities. A title's own \u{201C}Always use\u{201D} choice wins, and the sheet explains each automatic pick."
    ) {
      SettingsRow(
        title: "Preferred quality", detail: "Used when no release matches exactly, the closest is taken"
      ) {
        SettingsSelect(
          title: "Preferred quality",
          selection: Binding(
            get: { store.personal.preferences.preferredQuality ?? "highest" },
            set: { store.setPreferredQuality($0 == "highest" ? nil : $0) }),
          options: BestVersionPicker.qualityChoices.map {
            SettingsOption(value: $0, title: $0 == "highest" ? "Highest available" : $0)
          })
      }
    }
  }
}
