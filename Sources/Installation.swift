import AppKit
import Darwin
import Foundation

/// A path alone is not enough authority to recycle a download after a dialog.
struct InstallationFileStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let seconds: Int
    let nanoseconds: Int

    static func read(_ url: URL, regularFile: Bool = true) -> Self? {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == (regularFile ? S_IFREG : S_IFDIR) else { return nil }
        return Self(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                    seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }
}

struct InstallationImage {
    let volume: URL
    let volumeID: String
    let download: URL
    let downloadStamp: InstallationFileStamp

    static func volumeID(_ url: URL) -> String? {
        try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    func isMounted(volumeID: (URL) -> String? = Self.volumeID) -> Bool {
        volumeID(volume) == self.volumeID
    }

    /// Only a unique image containing this exact signed build is offered.
    static func matching(in data: Data, applicationName: String, signature: String,
                         readSignature: (String) throws -> String = lidSignature,
                         readVolumeID: (URL) -> String? = Self.volumeID) throws -> [Self] {
        guard data.count <= 1_100_000,
              let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return [] }
        var result = [Self]()
        for image in images {
            guard image["writeable"] as? Bool == false,
                  let path = image["image-path"] as? String,
                  !path.isEmpty, path.hasPrefix("/") else { continue }
            let download = URL(fileURLWithPath: path)
            guard download.pathExtension.lowercased() == "dmg",
                  let stamp = InstallationFileStamp.read(download),
                  let entities = image["system-entities"] as? [[String: Any]] else { continue }
            for entity in entities {
                guard let mount = entity["mount-point"] as? String, mount.hasPrefix("/") else { continue }
                let volume = URL(fileURLWithPath: mount, isDirectory: true)
                let app = volume.appendingPathComponent(applicationName)
                guard let uuid = readVolumeID(volume),
                      (try? readSignature(app.path)) == signature else { continue }
                result.append(Self(volume: volume, volumeID: uuid, download: download, downloadStamp: stamp))
            }
        }
        return result
    }

    static func unique(_ images: [Self]) -> Self? { images.count == 1 ? images[0] : nil }

    /// A busy disk is never forced out, and failed ejection never trashes a file.
    func clean(trashDownload: Bool,
               volumeID: (URL) -> String? = Self.volumeID,
               eject: (URL) throws -> Void = { try NSWorkspace.shared.unmountAndEjectDevice(at: $0) },
               trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        if isMounted(volumeID: volumeID) { try eject(volume) }
        guard !isMounted(volumeID: volumeID) else {
            throw LidError(L10n.text("설치 디스크를 사용 중인 앱이 있습니다. 디스크 안에서 실행 중인 앱을 닫고 다시 추출해주세요."))
        }
        guard trashDownload else { return }
        guard FileManager.default.fileExists(atPath: download.path) else { return }
        guard InstallationFileStamp.read(download) == downloadStamp else {
            throw LidError(L10n.text("디스크는 추출했지만 DMG 파일이 변경되어 휴지통으로 옮기지 않았습니다."))
        }
        try trash(download)
    }
}

enum InstallationFiles {
    static func isInstalled(_ app: URL, directories: [URL] = applicationDirectories) -> Bool {
        let path = app.resolvingSymlinksInPath().standardizedFileURL.path
        return directories.contains { path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/") }
    }

    static var applicationDirectories: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// Publish only a complete, verified copy. Finder owns replacement of an
    /// existing different version, including any required administrator dialog.
    static func copy(_ source: URL, to destination: URL,
                     readSignature: (String) throws -> String = lidSignature) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path),
              (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw LidError(L10n.text("같은 이름의 앱이 이미 있습니다. Finder에서 설치 화면의 앱을 응용 프로그램 폴더로 드래그해 교체해주세요."))
        }
        let expected = try readSignature(source.path)
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".softlock-install-" + UUID().uuidString)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }
        let stagedApp = stage.appendingPathComponent(destination.lastPathComponent)
        try manager.copyItem(at: source, to: stagedApp)
        guard try readSignature(stagedApp.path) == expected else {
            throw LidError(L10n.text("복사한 앱을 확인하지 못했습니다. 설치 파일을 다시 받아주세요."))
        }
        // moveItem refuses an existing destination instead of overwriting it.
        try manager.moveItem(at: stagedApp, to: destination)
    }

    static func imageInfo() throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count <= 1_100_000 else {
            throw LidError(L10n.text("설치 디스크 정보를 확인하지 못했습니다."))
        }
        return data
    }
}

/// Owns installation, launch handoff and explicit, recoverable image cleanup.
/// The normal app starts only after a disk-image launch has been resolved.
final class InstallationFlow {
    private let app = Bundle.main.bundleURL
    private let queue = DispatchQueue(label: "dev.local.softlock.installation", qos: .utility)
    private var image: InstallationImage?
    private var stopped = false
    private var cleanupOffered = false
    private var alert: NSAlert?
    private var relaunchWaiter: Timer?
    private var relaunchHandoff: RelaunchHandoff?
    private(set) var working = false
    var cleanupPending: Bool { image != nil && !cleanupOffered && !working }

    func begin(runApplication: @escaping () -> Void) {
        if let index = CommandLine.arguments.firstIndex(of: "--relaunch-handoff") {
            guard index + 1 < CommandLine.arguments.count,
                  let handoff = try? RelaunchHandoff.accept(CommandLine.arguments[index + 1]) else {
                NSApp.terminate(nil); return
            }
            relaunchHandoff = handoff
            working = true
            // Readiness is acknowledged before waiting. Only the predecessor
            // owns the timeout and cancellation; the child cannot race its exit.
            let waiter = Timer(timeInterval: 0.05, repeats: true) { [weak self] waiter in
                guard let self, !self.stopped else { waiter.invalidate(); return }
                switch handoff.predecessorState() {
                case .waiting: return
                case .cancelled:
                    waiter.invalidate(); self.relaunchWaiter = nil
                    self.relaunchHandoff = nil; self.working = false
                    NSApp.terminate(nil)
                case .released:
                    waiter.invalidate(); self.relaunchWaiter = nil
                    handoff.cancel(); self.relaunchHandoff = nil; self.working = false
                    self.continueNormal(runApplication)
                }
            }
            relaunchWaiter = waiter
            RunLoop.main.add(waiter, forMode: .common)
            return
        }
        let readOnly = (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
        guard readOnly && !InstallationFiles.isInstalled(app) else {
            continueNormal(runApplication)
            return
        }
        discover { [weak self] candidate in
            guard let self, !self.stopped else { return }
            self.image = candidate
            self.offerInstallation()
        }
    }

    private func discover(_ completion: @escaping (InstallationImage?) -> Void) {
        let application = app
        queue.async {
            let result = try? InstallationImage.matching(in: InstallationFiles.imageInfo(),
                applicationName: application.lastPathComponent, signature: lidSignature(application.path))
            DispatchQueue.main.async { completion(result.flatMap(InstallationImage.unique)) }
        }
    }

    private func others() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            guard $0.processIdentifier != getpid(), $0.bundleIdentifier == Bundle.main.bundleIdentifier,
                  !$0.isTerminated else { return false }
            // NSWorkspace snapshots may lag kernel exit by a main-loop turn.
            // Only ESRCH excludes a stale entry; permission/read failures keep
            // the normal singleton fence intact.
            return kill($0.processIdentifier, 0) == 0 || errno != ESRCH
        }
    }

    private func continueNormal(_ run: @escaping () -> Void, until: Date? = nil) {
        guard !stopped else { return }
        let running = others()
        if let other = running.first {
            // A source process quits after Launch Services acknowledges this app.
            // Wait for it rather than starting two input filters or ejecting it.
            let fromImage = other.bundleURL.flatMap {
                try? $0.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly
            } == true
            let deadline = until ?? Date().addingTimeInterval(8)
            if fromImage && Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.continueNormal(run, until: deadline) }
                return
            }
            other.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        run()
        if InstallationFiles.isInstalled(app) {
            discover { [weak self] candidate in
                guard let self, !self.stopped else { return }
                self.image = candidate
            }
        }
    }

    private func offerInstallation() {
        guard !stopped else { return }
        let destination = URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent(app.lastPathComponent)
        let sourceSignature = try? lidSignature(app.path)
        let installed = sourceSignature != nil && (try? lidSignature(destination.path)) == sourceSignature
        let question = Self.installAlert(installed: installed)
        alert = question
        NSApp.activate(ignoringOtherApps: true)
        let response = question.runModal()
        alert = nil
        guard response == .alertFirstButtonReturn else { NSApp.terminate(nil); return }
        if let existing = others().first {
            let expected = try? lidSignature(destination.path)
            if installed, existing.bundleURL?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath(), let expected,
               lidPeerIsAllowed(existing.processIdentifier, uid: getuid(), configuration:
                    ["uid": getuid(), "clientRequirement": "cdhash H\"\(expected)\""]) {
                existing.activate(options: [.activateAllWindows])
                NSApp.terminate(nil); return
            }
            explain(L10n.text("DeskVeil이 이미 실행 중입니다"), L10n.text("기존 앱에서 입력 차단을 해제하고 종료한 뒤 다시 설치해주세요."))
            DispatchQueue.main.async { [weak self] in self?.offerInstallation() }
            return
        }
        if !installed {
            do { try InstallationFiles.copy(app, to: destination) }
            catch {
                explain(L10n.text("Finder에서 설치를 마무리해주세요"), error.localizedDescription)
                if let image { NSWorkspace.shared.open(image.volume) }
                NSApp.terminate(nil)
                return
            }
        }
        working = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--show-controls"]
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { [weak self] running, error in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.working = false
                if let running, running.bundleURL?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() {
                    NSApp.terminate(nil)
                } else {
                    self.explain(L10n.text("앱은 복사됐지만 열지 못했습니다"), error?.localizedDescription ?? L10n.text("응용 프로그램에서 DeskVeil을 직접 열어주세요."))
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                    NSApp.terminate(nil)
                }
            }
        }
    }

    static func installAlert(installed: Bool) -> NSAlert {
        let question = NSAlert()
        question.messageText = installed ? L10n.text("설치된 앱을 열까요?") : L10n.text("DeskVeil을 설치할까요?")
        question.informativeText = installed ? L10n.text("응용 프로그램에 설치된 DeskVeil을 실행합니다.") :
            L10n.text("응용 프로그램으로 복사한 뒤 바로 실행합니다.")
        question.addButton(withTitle: installed ? L10n.text("설치된 앱 열기") : L10n.text("설치하고 열기"))
        question.addButton(withTitle: L10n.text("취소"))
        question.accessoryView = fileDetails(icon: NSWorkspace.shared.icon(forFile: "/Applications"),
            title: L10n.text("응용 프로그램"), subtitle: L10n.text("설치 위치"))
        return question
    }

    private static func fileDetails(icon: NSImage, title: String, subtitle: String) -> NSView {
        let image = NSImageView(image: icon)
        image.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(labelWithString: subtitle)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 3
        let row = NSStackView(views: [image, labels])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
        let box = NSBox(frame: NSRect(x: 0, y: 0, width: 340, height: 62))
        box.boxType = .custom
        box.borderWidth = 0.5; box.borderColor = .separatorColor
        box.cornerRadius = 8; box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        box.contentView!.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 340),
            box.heightAnchor.constraint(equalToConstant: 62),
            image.widthAnchor.constraint(equalToConstant: 32),
            image.heightAnchor.constraint(equalToConstant: 32),
            row.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: box.contentView!.centerYAnchor)
        ])
        return box
    }

    static func cleanupAlert(download: URL) -> (alert: NSAlert, checkbox: NSButton) {
        let question = NSAlert()
        question.messageText = L10n.text("DeskVeil 설치 완료")
        question.informativeText = L10n.text("설치 디스크는 이제 추출해도 됩니다.")
        question.addButton(withTitle: L10n.text("디스크 추출"))
        question.addButton(withTitle: L10n.text("나중에"))
        let checkbox = NSButton(checkboxWithTitle: L10n.text("DMG 파일도 휴지통으로 이동"), target: nil, action: nil)
        checkbox.state = .off
        checkbox.toolTip = L10n.text("설치된 DeskVeil은 유지하고 이 DMG 파일만 휴지통으로 옮깁니다.")
        let diskIcon = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))!
        let file = fileDetails(icon: diskIcon,
            title: download.lastPathComponent, subtitle: L10n.text("설치 파일"))
        file.toolTip = download.path
        let accessory = NSStackView(views: [file, checkbox])
        accessory.orientation = .vertical; accessory.alignment = .leading; accessory.spacing = 12
        accessory.frame = NSRect(x: 0, y: 0, width: 340, height: 94)
        question.accessoryView = accessory
        return (question, checkbox)
    }

    func offerCleanup(in window: NSWindow) {
        guard cleanupPending, window.attachedSheet == nil, let image else { return }
        cleanupOffered = true
        let (question, checkbox) = Self.cleanupAlert(download: image.download)
        alert = question
        question.beginSheetModal(for: window) { [weak self] response in
            guard let self, !self.stopped else { return }
            self.alert = nil
            guard response == .alertFirstButtonReturn else { return }
            self.working = true
            let trash = checkbox.state == .on
            self.queue.async {
                let result = Result { try image.clean(trashDownload: trash) }
                DispatchQueue.main.async {
                    guard !self.stopped else { return }
                    self.working = false
                    if case .failure(let error) = result {
                        let failure = NSAlert()
                        failure.messageText = L10n.text("설치 디스크 정리를 마치지 못했습니다")
                        failure.informativeText = error.localizedDescription
                        failure.addButton(withTitle: L10n.text("확인"))
                        self.alert = failure
                        failure.beginSheetModal(for: window) { [weak self] _ in self?.alert = nil }
                    }
                }
            }
        }
    }

    func dismissCleanup() {
        if let window = alert?.window, let parent = window.sheetParent {
            parent.endSheet(window, returnCode: .alertSecondButtonReturn)
        }
    }

    func raise() { alert?.window.makeKeyAndOrderFront(nil) }
    func stop() {
        stopped = true; relaunchWaiter?.invalidate(); relaunchWaiter = nil
        relaunchHandoff?.cancel(); relaunchHandoff = nil
        dismissCleanup()
    }

    private func explain(_ title: String, _ message: String) {
        let explanation = NSAlert()
        explanation.messageText = title; explanation.informativeText = message
        explanation.addButton(withTitle: L10n.text("확인"))
        explanation.runModal()
    }
}
