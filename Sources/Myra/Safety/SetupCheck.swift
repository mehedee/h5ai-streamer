import Foundation

/// The first-run checks. Each returns a plain result the setup sheet can show as a row.
enum SetupCheck {
  struct Result: Equatable, Sendable, Identifiable {
    enum Status: Equatable, Sendable { case ok, warning, failed }

    let id: String
    let title: String
    let status: Status
    let detail: String
  }

  /// First run is shown only when there is no saved library: no sources and no index file.
  static func needsFirstRun(sourceCount: Int, libraryFileExists: Bool) -> Bool {
    sourceCount == 0 && !libraryFileExists
  }

  /// True when the library index file exists in the app's data folder (or the isolated profile).
  static func libraryFileExists(fileManager: FileManager = .default) -> Bool {
    guard let folder = try? AppPersistence.persistentStoreURL().deletingLastPathComponent() else {
      return false
    }
    return fileManager.fileExists(atPath: folder.appending(path: "LibraryIndex.sqlite").path)
  }

  /// A source must be a web address of a directory listing, as the engine reads it.
  static func sourceAddressCheck(_ text: String) -> Result {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
    guard let components = URLComponents(string: withScheme),
      let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
      components.host?.isEmpty == false
    else {
      return Result(
        id: "source-address", title: "Source address", status: .failed,
        detail: "Enter a web address such as http://nas.local/movies/.")
    }
    return Result(
      id: "source-address", title: "Source address", status: .ok, detail: "Address is well formed.")
  }

  /// The download folder must exist and be writable. A missing folder is created on first download,
  /// so only an existing, unwritable one is a failure.
  static func downloadFolderCheck(path: String, fileManager: FileManager = .default) -> Result {
    var isDirectory: ObjCBool = false
    let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
    if exists, !isDirectory.boolValue {
      return Result(
        id: "downloads", title: "Download folder", status: .failed,
        detail: "The path exists but is a file, not a folder.")
    }
    if exists, !fileManager.isWritableFile(atPath: path) {
      return Result(
        id: "downloads", title: "Download folder", status: .failed,
        detail: "Myra cannot write to this folder. Choose another in Settings.")
    }
    if !exists {
      return Result(
        id: "downloads", title: "Download folder", status: .warning,
        detail: "Will be created when the first download starts.")
    }
    return Result(id: "downloads", title: "Download folder", status: .ok, detail: "Writable.")
  }

  /// Result of asking the engine to read a source listing.
  static func readabilityResult(name: String, readable: Bool, message: String?) -> Result {
    Result(
      id: "source-\(name)", title: name, status: readable ? .ok : .failed,
      detail: readable ? "Readable and listing videos." : (message ?? "The folder could not be read."))
  }
}
