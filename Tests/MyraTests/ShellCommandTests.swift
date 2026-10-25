import Foundation
import XCTest

@testable import Myra

@MainActor
final class ShellCommandTests: XCTestCase {
  func testEveryCommandIdentifierRoundTrips() {
    let identifiers = MyraCommand.allCommands.map(\.identifier)
    XCTAssertEqual(Set(identifiers).count, identifiers.count, "Identifiers must be unique")
    for command in MyraCommand.allCommands {
      XCTAssertEqual(MyraCommand(identifier: command.identifier), command)
    }
  }

  func testAppearanceCommandsCarryTheirMode() {
    XCTAssertEqual(MyraCommand(identifier: "setAppearance.dark"), .setAppearance(.dark))
    XCTAssertEqual(MyraCommand(identifier: "setAppearance.light"), .setAppearance(.light))
    XCTAssertEqual(MyraCommand(identifier: "setAppearance.system"), .setAppearance(.system))
    XCTAssertNil(MyraCommand(identifier: "setAppearance.sepia"))
  }

  func testUnknownIdentifierIsRejected() {
    XCTAssertNil(MyraCommand(identifier: "doesNotExist"))
    XCTAssertNil(MyraCommand(identifier: ""))
  }

  func testPostedCommandIsDeliveredOnPrivateCenter() {
    let center = NotificationCenter()
    var received: [MyraCommand] = []
    let token = center.addObserver(forName: MyraCommand.notification, object: nil, queue: nil) {
      note in
      if let command = MyraCommand(notification: note) { received.append(command) }
    }
    defer { center.removeObserver(token) }

    MyraCommand.showTransfers.post(center: center)
    MyraCommand.setAppearance(.dark).post(center: center)

    XCTAssertEqual(received, [.showTransfers, .setAppearance(.dark)])
  }

  func testNotificationWithoutCommandKeyIsIgnored() {
    let note = Notification(name: MyraCommand.notification, object: nil, userInfo: nil)
    XCTAssertNil(MyraCommand(notification: note))
  }

  func testPlaybackCommandsNeedOpenMedia() {
    let idle = MyraCommandContext()
    let playing = MyraCommandContext(isPlayingMedia: true)
    for command in [
      MyraCommand.togglePlayback, .skipBack, .skipForward, .previousEpisode, .nextEpisode,
    ] {
      XCTAssertFalse(command.availability(in: idle).isEnabled, "\(command.identifier)")
      XCTAssertTrue(command.availability(in: playing).isEnabled, "\(command.identifier)")
    }
  }

  func testDownloadCommandsFollowBatchState() {
    let idle = MyraCommandContext()
    XCTAssertFalse(MyraCommand.pauseAllDownloads.availability(in: idle).isEnabled)
    XCTAssertFalse(MyraCommand.resumeAllDownloads.availability(in: idle).isEnabled)
    XCTAssertFalse(MyraCommand.clearCompletedDownloads.availability(in: idle).isEnabled)

    let busy = MyraCommandContext(
      hasActiveDownloads: true, hasPausedDownloads: true, hasCompletedDownloads: true)
    XCTAssertTrue(MyraCommand.pauseAllDownloads.availability(in: busy).isEnabled)
    XCTAssertTrue(MyraCommand.resumeAllDownloads.availability(in: busy).isEnabled)
    XCTAssertTrue(MyraCommand.clearCompletedDownloads.availability(in: busy).isEnabled)
  }

  func testAddSourceAndFindFollowTheVisibleSection() {
    let sources = MyraCommandContext(currentSection: .sources)
    XCTAssertTrue(MyraCommand.addSource.availability(in: sources).isEnabled)
    XCTAssertTrue(MyraCommand.find.availability(in: sources).isEnabled)

    let transfers = MyraCommandContext(currentSection: .transfers)
    for command in [MyraCommand.addSource, .find] {
      guard case .disabled(let reason) = command.availability(in: transfers) else {
        return XCTFail("\(command.identifier) should be disabled outside its pages")
      }
      XCTAssertFalse(reason.isEmpty)
    }
    XCTAssertTrue(MyraCommand.openTorrentLink.availability(in: transfers).isEnabled)
  }

  func testNavigationAndWindowCommandsAreAlwaysEnabled() {
    let idle = MyraCommandContext()
    for command in [
      MyraCommand.showHome, .showSources, .showDownloads, .showTransfers, .importTorrentFile,
      .refreshLibrary, .toggleFullScreen, .setAppearance(.light),
    ] {
      XCTAssertTrue(command.availability(in: idle).isEnabled, "\(command.identifier)")
    }
  }
}
