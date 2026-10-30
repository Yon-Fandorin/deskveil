import Foundation
import XCTest
@testable import SoftLock

final class InstallationTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("softlock-install-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func image() throws -> InstallationImage {
        let file = directory.appendingPathComponent("SoftLock.dmg")
        try Data("download".utf8).write(to: file)
        return InstallationImage(volume: directory.appendingPathComponent("Mounted"), volumeID: "original-volume",
                                 download: file, downloadStamp: try XCTUnwrap(InstallationFileStamp.read(file)))
    }

    func testInventoryRequiresAnExactSignedBuildAndNeverGuessesBetweenImages() throws {
        let candidate = try image()
        func entry(_ path: String, writable: Bool = false) -> [String: Any] {
            ["image-path": path, "writeable": writable, "system-entities": [["mount-point": candidate.volume.path]]]
        }
        func match(_ entries: [[String: Any]], hash: String = "expected") throws -> [InstallationImage] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["images": entries], format: .xml, options: 0)
            return try InstallationImage.matching(in: data, applicationName: "SoftLock.app", signature: "expected",
                readSignature: { _ in hash }, readVolumeID: { _ in "original-volume" })
        }
        XCTAssertNotNil(InstallationImage.unique(try match([entry(candidate.download.path)])))
        XCTAssertTrue(try match([entry(candidate.download.path)], hash: "different-build").isEmpty)
        XCTAssertTrue(try match([entry(candidate.download.path, writable: true)]).isEmpty)
        let link = directory.appendingPathComponent("Symlink.dmg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: candidate.download)
        XCTAssertTrue(try match([entry(link.path)]).isEmpty)
        XCTAssertNil(InstallationImage.unique(try match([entry(candidate.download.path), entry(candidate.download.path)])))
    }

    func testCleanupRequiresSuccessfulEjectionAndExplicitTrashChoice() throws {
        let candidate = try image()
        var mounted: String? = candidate.volumeID
        var events: [String] = []
        XCTAssertThrowsError(try candidate.clean(trashDownload: true, volumeID: { _ in mounted },
            eject: { _ in events.append("busy"); throw NSError(domain: "busy", code: 1) },
            trash: { _ in XCTFail("A busy image was trashed") }))
        XCTAssertEqual(events, ["busy"])
        try candidate.clean(trashDownload: false, volumeID: { _ in mounted },
            eject: { _ in mounted = nil; events.append("eject") },
            trash: { _ in XCTFail("The checkbox was not selected") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.download.path))
        mounted = candidate.volumeID
        try candidate.clean(trashDownload: true, volumeID: { _ in mounted },
            eject: { _ in mounted = nil; events.append("eject") },
            trash: { url in
                XCTAssertNil(mounted)
                XCTAssertEqual(url, candidate.download)
                events.append("trash")
            })
        XCTAssertEqual(events, ["busy", "eject", "eject", "trash"])
    }

    func testChangedDownloadAndReusedMountPointCannotAffectUnrelatedData() throws {
        let candidate = try image()
        try Data("replacement file".utf8).write(to: candidate.download, options: .atomic)
        XCTAssertThrowsError(try candidate.clean(trashDownload: true, volumeID: { _ in "another-volume" },
            eject: { _ in XCTFail("Ejected a different volume at the old mount point") },
            trash: { _ in XCTFail("Trashed a file replaced while the dialog was open") }))
        XCTAssertEqual(try String(contentsOf: candidate.download, encoding: .utf8), "replacement file")
    }

    func testApplicationCopyPublishesOnlyVerifiedDataAndPreservesExistingApps() throws {
        let source = directory.appendingPathComponent("Source.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("signed app".utf8).write(to: source.appendingPathComponent("payload"))
        let target = directory.appendingPathComponent("Installed.app")
        func signature(_ path: String) throws -> String {
            try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("payload")).base64EncodedString()
        }
        XCTAssertThrowsError(try InstallationFiles.copy(source, to: target, readSignature: { path in
            path == source.path ? "original" : "tampered"
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        try InstallationFiles.copy(source, to: target, readSignature: signature)
        XCTAssertEqual(try signature(target.path), try signature(source.path))
        try Data("existing user app".utf8).write(to: target.appendingPathComponent("payload"))
        XCTAssertThrowsError(try InstallationFiles.copy(source, to: target, readSignature: signature))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("payload"), encoding: .utf8), "existing user app")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".softlock-install-") })
    }

    func testDestinationAppearingDuringCopyIsNotOverwritten() throws {
        let source = directory.appendingPathComponent("Source.app")
        let target = directory.appendingPathComponent("Installed.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        XCTAssertThrowsError(try InstallationFiles.copy(source, to: target, readSignature: { path in
            if path != source.path {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                try Data("other installer".utf8).write(to: target.appendingPathComponent("preserve"))
            }
            return "signed app"
        }))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("preserve"), encoding: .utf8), "other installer")
    }

    func testOnlyApplicationDirectoriesCountAsInstalled() {
        let apps = directory.appendingPathComponent("Applications")
        XCTAssertTrue(InstallationFiles.isInstalled(apps.appendingPathComponent("Tools/SoftLock.app"), directories: [apps]))
        XCTAssertFalse(InstallationFiles.isInstalled(directory.appendingPathComponent("Applications-copy/SoftLock.app"), directories: [apps]))
    }
}
