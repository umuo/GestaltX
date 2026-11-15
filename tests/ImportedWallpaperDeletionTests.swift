// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main enum ImportedWallpaperDeletionTests {
    static let fm = FileManager.default
    static func require(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
        if try !condition() {
            throw NSError(domain: "ImportedWallpaperDeletionTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: reason])
        }
    }
    static func rejects(_ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { return }
        try require(false, "Unsafe operation was accepted")
    }
    static func importFolder(_ pack: WallpaperPack, storage: URL) -> URL {
        storage.appendingPathComponent("Wallpapers/\(pack.id.uuidString)")
    }
    static func recordsURL(_ id: UUID, storage: URL) -> URL {
        storage.appendingPathComponent("WallpaperInstallations/\(id.uuidString).plist")
    }
    static func makeImport(_ pack: WallpaperPack, storage: URL) throws -> Data {
        let directory = importFolder(pack, storage: storage)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("imported assets".utf8).write(to: directory.appendingPathComponent("Asset.bin"))
        try CustomizationFiles.saveVerified(pack, to: directory.appendingPathComponent("Pack.plist"))
        // Future manifest fields must survive deletion even if WallpaperPack does not decode them.
        var values = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: directory.appendingPathComponent("Pack.plist")), format: nil) as! [String: Any]
        values["futureInstallationMetadata"] = ["version": 2]
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        try data.write(to: directory.appendingPathComponent("Pack.plist"))
        return data
    }
    static func localStore(_ storage: URL, device: String = "original-device") -> CustomizationStore {
        CustomizationStore(storage: storage, device: device, resolver: { _ in
            fatalError("Deleting an imported wallpaper requested system-container access")
        })
    }
    static func main() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("GX-ImportedWallpaperDeletion-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        try await unapplied(root.appendingPathComponent("Unapplied"))
        for device in ["original-device", "changed-device"] {
            for changed in [false, true] {
                try await applied(root.appendingPathComponent("\(device)-\(changed)"), device: device, changed: changed)
            }
        }
        try await failedRecordWrite(root.appendingPathComponent("FailedRecordWrite"))
        try await repeatedImport(root.appendingPathComponent("RepeatedImport"))
        try await refreshFailure(root.appendingPathComponent("RefreshFailure"))
        try await coversAndRows(root.appendingPathComponent("CoversAndRows"))
        try await reverifyAfterResigning(root.appendingPathComponent("Reverify"))
        try await fileReadRegressions(root.appendingPathComponent("FileReads"))
        try await reviewedRemoval(root.appendingPathComponent("ReviewedRemoval"))
        try await links(root.appendingPathComponent("Links"))
        print("Imported wallpaper deletion tests passed: local-only deletion, changed device/content, exact manifests, durable failures, archived uninstall, repeated UUIDs, partial installs and symlink containment.")
    }
    static func unapplied(_ storage: URL) async throws {
        let pack = WallpaperPack(id: UUID(), name: "Unapplied", descriptors: [])
        let other = WallpaperPack(id: UUID(), name: "Other", descriptors: [])
        _ = try makeImport(pack, storage: storage)
        let otherData = try makeImport(other, storage: storage)
        let store = localStore(storage)
        try await store.deleteImportedWallpaper(pack.id)
        try await store.deleteImportedWallpaper(pack.id)
        let listed = try await store.listWallpapers()
        try require(listed.map(\.id) == [other.id], "Deleted import remains listed or another pack was removed")
        let installed = try await store.listInstalledWallpapers()
        try require(installed.isEmpty, "Unapplied imports appeared in the system removal list")
        try require(!fm.fileExists(atPath: importFolder(pack, storage: storage).path), "Import directory remains")
        try require(!fm.fileExists(atPath: recordsURL(pack.id, storage: storage).path), "Unapplied pack created installation records")
        try require(try Data(contentsOf: importFolder(other, storage: storage).appendingPathComponent("Pack.plist")) == otherData, "Another pack changed")
    }
    static func applied(_ storage: URL, device: String, changed: Bool) async throws {
        let poster = storage.appendingPathComponent("FakePosterBoard")
        let relative = "Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors/\(UUID().uuidString)"
        let target = poster.appendingPathComponent(relative)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let original = Data("installed wallpaper".utf8)
        let file = target.appendingPathComponent("Wallpaper.bin")
        try original.write(to: file)
        let entry = WallpaperInstallation(relative: relative, files: try CustomizationFiles.tree(target), committed: true)
        let pack = WallpaperPack(id: UUID(), name: "Applied", descriptors: [], installations: [entry], installedDevice: "original-device")
        let manifest = try makeImport(pack, storage: storage)
        let other = WallpaperPack(id: UUID(), name: "Other", descriptors: [])
        let otherManifest = try makeImport(other, storage: storage)
        let unrelated = target.deletingLastPathComponent().appendingPathComponent("existing/Keep.bin")
        try fm.createDirectory(at: unrelated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unrelated wallpaper".utf8).write(to: unrelated)
        if changed { try Data("changed outside GestaltX".utf8).write(to: file) }
        let before = try CustomizationFiles.tree(poster)
        let beforeDeletion = try await localStore(storage, device: device).listInstalledWallpapers()
        try require(beforeDeletion.map(\.id) == [pack.id], "Applied pack missing from the system removal list")
        try await localStore(storage, device: device).deleteImportedWallpaper(pack.id)
        let archived = try await localStore(storage, device: device).listInstalledWallpapers()
        try require(archived.map(\.id) == [pack.id], "Deleted import cannot be found for system removal")
        try require(!fm.fileExists(atPath: importFolder(pack, storage: storage).path), "Applied import was not deleted")
        try require(try CustomizationFiles.tree(poster) == before, "Local deletion changed system wallpapers")
        let record = recordsURL(pack.id, storage: storage)
        let saved = try PropertyListDecoder().decode([Data].self, from: Data(contentsOf: record))
        try require(saved == [manifest], "Complete installation manifest was not preserved")
        try require(try Data(contentsOf: importFolder(other, storage: storage).appendingPathComponent("Pack.plist")) == otherManifest, "Another imported pack changed")
        let changedDevice = CustomizationStore(storage: storage, device: "changed-device", resolver: { _ in poster })
        try await rejects { _ = try await changedDevice.removeWallpaper(pack.id) }
        try require(fm.fileExists(atPath: record.path), "Device mismatch lost archived ownership")
        let uninstaller = CustomizationStore(storage: storage, device: "original-device", resolver: { _ in poster })
        if changed {
            try await rejects { _ = try await uninstaller.removeWallpaper(pack.id) }
            try require(try CustomizationFiles.tree(poster) == before, "Uninstall removed an externally changed wallpaper")
            try require(fm.fileExists(atPath: record.path), "Refused uninstall lost archived ownership")
            try original.write(to: file)
        }
        let remaining = try await uninstaller.removeWallpaper(pack.id)
        try require(remaining.map(\.id) == [other.id], "Archived uninstall affected another import")
        try require(!fm.fileExists(atPath: target.path), "Archived uninstall requires the deleted import")
        try require(fm.fileExists(atPath: unrelated.path), "Uninstall deleted an unowned descriptor")
        try require(!fm.fileExists(atPath: record.path), "Completed uninstall left obsolete ownership")
        let installedAfter = try await uninstaller.listInstalledWallpapers()
        try require(installedAfter.isEmpty, "Removed wallpaper remains in the system removal list")
        let prefs = poster.appendingPathComponent("Library/Preferences/com.apple.PosterBoard.unprotectedUserDefaults.plist")
        let refresh = try PropertyListSerialization.propertyList(from: Data(contentsOf: prefs), format: nil) as! [String: Any]
        try require(refresh["PBF_RESET_FILE_PROTECTIONS"] as? Bool == true, "System removal did not request a gallery refresh")
    }
    static func failedRecordWrite(_ storage: URL) async throws {
        let pack = WallpaperPack(id: UUID(), name: "Applied", descriptors: [],
                                 installations: [.init(relative: "tracked", files: [:])], installedDevice: "old-device")
        let manifest = try makeImport(pack, storage: storage)
        let blocker = storage.appendingPathComponent("WallpaperInstallations")
        try Data("not a directory".utf8).write(to: blocker)
        let store = localStore(storage)
        try await rejects { try await store.deleteImportedWallpaper(pack.id) }
        try require(try Data(contentsOf: importFolder(pack, storage: storage).appendingPathComponent("Pack.plist")) == manifest, "Failed record write deleted the original pack")
        let listed = try await store.listWallpapers()
        try require(listed.map(\.id) == [pack.id], "Failed deletion lost the list item")
        try fm.removeItem(at: blocker)
        try await store.deleteImportedWallpaper(pack.id)
        try require(fm.fileExists(atPath: recordsURL(pack.id, storage: storage).path), "Retry did not preserve installation records")
    }
    static func repeatedImport(_ storage: URL) async throws {
        let poster = storage.appendingPathComponent("FakePosterBoard")
        let provider = "Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"
        let id = UUID()
        let store = localStore(storage)
        var manifests: [Data] = []
        var paths: [URL] = []
        for committed in [true, false] {
            let relative = provider + "/" + UUID().uuidString
            let target = poster.appendingPathComponent(relative)
            let actual = committed ? target : target.deletingLastPathComponent().appendingPathComponent(".GestaltX-stage-\(target.lastPathComponent)")
            try fm.createDirectory(at: actual, withIntermediateDirectories: true)
            try Data("installed".utf8).write(to: actual.appendingPathComponent("Wallpaper.bin"))
            let entry = WallpaperInstallation(relative: relative, files: try CustomizationFiles.tree(actual), committed: committed)
            let pack = WallpaperPack(id: id, name: "Reimported", descriptors: [], installations: [entry], installedDevice: "original-device")
            manifests.append(try makeImport(pack, storage: storage))
            paths.append(actual)
            let combined = try await store.listInstalledWallpapers()
            try require(combined.count == 1 && combined[0].installations.count == paths.count, "Live and archived installations were not combined")
            try await store.deleteImportedWallpaper(id)
        }
        let saved = try PropertyListDecoder().decode([Data].self, from: Data(contentsOf: recordsURL(id, storage: storage)))
        try require(saved == manifests, "A reused pack UUID overwrote older installation records")
        let installed = try await store.listInstalledWallpapers()
        try require(installed.count == 1 && installed[0].installations.count == 2, "Archived snapshots were lost or shown as duplicate packs")
        _ = try await CustomizationStore(storage: storage, device: "original-device", resolver: { _ in poster }).removeWallpaper(id)
        for path in paths { try require(!fm.fileExists(atPath: path.path), "An archived or partial installation was orphaned") }
    }
    static func refreshFailure(_ storage: URL) async throws {
        let poster = storage.appendingPathComponent("FakePosterBoard")
        let relative = "Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors/\(UUID().uuidString)"
        let target = poster.appendingPathComponent(relative)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("installed".utf8).write(to: target.appendingPathComponent("Wallpaper.bin"))
        let pack = WallpaperPack(id: UUID(), name: "Refresh retry", descriptors: [],
                                 installations: [.init(relative: relative, files: try CustomizationFiles.tree(target), committed: true)],
                                 installedDevice: "original-device")
        _ = try makeImport(pack, storage: storage)
        let store = CustomizationStore(storage: storage, device: "original-device", resolver: { _ in poster })
        try await store.deleteImportedWallpaper(pack.id)
        let prefs = poster.appendingPathComponent("Library/Preferences/com.apple.PosterBoard.unprotectedUserDefaults.plist")
        try fm.createDirectory(at: prefs.deletingLastPathComponent(), withIntermediateDirectories: true)
        let incompatible = try PropertyListSerialization.data(fromPropertyList: ["unexpected array"], format: .binary, options: 0)
        try incompatible.write(to: prefs)
        _ = try await store.removeWallpaper(pack.id)
        let removedDespiteRefresh = try await store.listInstalledWallpapers()
        let warning = await store.wallpaperRemovalRefreshWarning
        try require(removedDespiteRefresh.isEmpty && !fm.fileExists(atPath: target.path), "Completed file deletion was reported as a failed uninstall")
        try require(warning != nil, "Gallery refresh failure was not surfaced as a separate warning")
        try require(warning == "The files changed. Read again before applying.", "The reported refresh error was not reproduced")
        let original = try PropertyListSerialization.data(fromPropertyList: ["unrelated": "keep"], format: .binary, options: 0)
        try original.write(to: prefs)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("installed".utf8).write(to: target.appendingPathComponent("Wallpaper.bin"))
        _ = try makeImport(pack, storage: storage)
        _ = try await store.removeWallpaper(pack.id)
        let removed = try await store.listInstalledWallpapers()
        try require(removed.isEmpty, "Refresh retry did not complete removal")
        let cleared = await store.wallpaperRemovalRefreshWarning
        try require(cleared == nil, "A later successful removal retained a stale gallery warning")
        let merged = try PropertyListSerialization.propertyList(from: Data(contentsOf: prefs), format: nil) as! [String: Any]
        try require(merged["unrelated"] as? String == "keep", "Gallery refresh replaced unrelated preferences")
    }
    static func coversAndRows(_ storage: URL) async throws {
        let poster = storage.appendingPathComponent("FakePosterBoard")
        let relative = "Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors/\(UUID().uuidString)"
        let target = poster.appendingPathComponent(relative)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!
        let cover = try CustomizationImages.png(png, size: 640)
        let file = target.appendingPathComponent("poster.png")
        try cover.write(to: file)
        let pack = WallpaperPack(id: UUID(), name: "Same name", descriptors: [], preview: "Preview.png",
                                 installations: [.init(relative: relative, files: try CustomizationFiles.tree(target), committed: true)],
                                 installedDevice: "original-device")
        _ = try makeImport(pack, storage: storage)
        try cover.write(to: importFolder(pack, storage: storage).appendingPathComponent("Preview.png"))
        let store = CustomizationStore(storage: storage, device: "original-device", resolver: { _ in poster })
        let rows = WallpaperPack.listRows(imported: [pack], installed: [pack])
        try require(rows.count == 1, "The same import and installation appeared twice")
        let copy = WallpaperPack(id: UUID(), name: pack.name, descriptors: [], installations: pack.installations)
        try require(WallpaperPack.listRows(imported: [pack, copy], installed: [pack]).count == 2,
                    "Same-name installations were merged, making targeted removal ambiguous")
        try await store.deleteImportedWallpaper(pack.id)
        let cached = try await localStore(storage).wallpaperPreview(pack.id)
        try require(cached != nil, "Deleting imported assets lost the cover or required system access")
        let cache = storage.appendingPathComponent("WallpaperPreviews/\(pack.id.uuidString).plist")
        try fm.removeItem(at: cache)
        let recovered = try await store.wallpaperPreview(pack.id)
        try require(recovered != nil, "A previously deleted import could not recover its installed cover")
        try fm.removeItem(at: cache)
        try Data("changed image".utf8).write(to: file)
        let changed = try await store.wallpaperPreview(pack.id)
        try require(changed == nil, "An unverified changed image was displayed as this installation's cover")
        let foreign = try await localStore(storage, device: "other-device").wallpaperPreview(pack.id)
        try require(foreign == nil, "A foreign installation triggered system-container access for its cover")
        try cover.write(to: file)
        _ = try await store.wallpaperPreview(pack.id)
        _ = try await store.removeWallpaper(pack.id)
        try require(!fm.fileExists(atPath: cache.path), "Uninstalled wallpaper left a stale cover cache")
    }
    static func reverifyAfterResigning(_ storage: URL) async throws {
        let poster = storage.appendingPathComponent("FakePosterBoard")
        let relative = "Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors/\(UUID().uuidString)"
        let target = poster.appendingPathComponent(relative)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let file = target.appendingPathComponent("Wallpaper.bin")
        let original = Data("owned wallpaper".utf8)
        try original.write(to: file)
        let pack = WallpaperPack(id: UUID(), name: "Re-signed", descriptors: [],
                                 installations: [.init(relative: relative, files: try CustomizationFiles.tree(target), committed: true)],
                                 installedDevice: "previous-signature")
        let oldManifest = try makeImport(pack, storage: storage)
        let oldStore = CustomizationStore(storage: storage, device: "previous-signature", resolver: { _ in poster })
        try await oldStore.deleteImportedWallpaper(pack.id)
        // Keep a live import with the same UUID as well as its archived snapshot.
        _ = try makeImport(pack, storage: storage)
        let current = CustomizationStore(storage: storage, device: "new-signature", resolver: { _ in poster })
        try await rejects { _ = try await current.removeWallpaper(pack.id) }
        try Data("changed outside app".utf8).write(to: file)
        try await rejects { try await current.verifyWallpaperInstallation(pack.id) }
        let unchanged = try PropertyListDecoder().decode([Data].self, from: Data(contentsOf: recordsURL(pack.id, storage: storage)))
        try require(unchanged == [oldManifest], "Failed verification changed the archived binding")
        try original.write(to: file)
        let before = try CustomizationFiles.tree(poster)
        try await current.verifyWallpaperInstallation(pack.id)
        try require(try CustomizationFiles.tree(poster) == before, "Verification modified system files")
        let installed = try await current.listInstalledWallpapers()
        try require(installed.count == 1 && installed[0].installedDevice == "new-signature", "Verified binding was not updated")
        let snapshots = try PropertyListDecoder().decode([Data].self, from: Data(contentsOf: recordsURL(pack.id, storage: storage)))
        for data in snapshots + [try Data(contentsOf: importFolder(pack, storage: storage).appendingPathComponent("Pack.plist"))] {
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
            try require(plist["futureInstallationMetadata"] != nil, "Verification discarded unknown manifest fields")
        }
        // Removal must still check the bytes again after a successful verification.
        try Data("changed after verification".utf8).write(to: file)
        try await rejects { _ = try await current.removeWallpaper(pack.id) }
        try original.write(to: file)
        let prefsPath = "Library/Preferences/com.apple.PosterBoard.unprotectedUserDefaults.plist"
        try CustomizationFileTransaction(root: poster, storage: storage.appendingPathComponent("PosterBoardDefaults"), device: "previous-signature")
            .replace([prefsPath: PropertyListSerialization.data(fromPropertyList: ["keep": true], format: .binary, options: 0)])
        _ = try await current.removeWallpaper(pack.id)
        try require(!fm.fileExists(atPath: target.path), "Reverified wallpaper could not be removed")
        let prefs = try PropertyListSerialization.propertyList(from: Data(contentsOf: poster.appendingPathComponent(prefsPath)), format: nil) as! [String: Any]
        try require(prefs["keep"] as? Bool == true, "Gallery refresh lost unrelated settings after re-signing")
        // A record alone is not enough to adopt a nonexistent installation.
        _ = try makeImport(pack, storage: storage)
        try await rejects { try await current.verifyWallpaperInstallation(pack.id) }
        _ = try await current.removeWallpaper(pack.id)
        let staleRecords = try await current.listInstalledWallpapers()
        try require(staleRecords.isEmpty, "A stale cross-signature record with no system files could not be cleared")
    }
    static func fileReadRegressions(_ storage: URL) async throws {
        try fm.createDirectory(at: storage, withIntermediateDirectories: true)
        let empty = storage.appendingPathComponent("empty-marker")
        try Data().write(to: empty)
        try require(try CustomizationFiles.read(empty).isEmpty, "A valid empty file was reported as changed")
        let hashes = try CustomizationFiles.tree(storage)
        try require(hashes["empty-marker"] == CustomizationFiles.digest(Data()), "Empty files cannot be hashed during preflight")
        let payload = Data(repeating: 73, count: 2 * 1024 * 1024 + 13)
        let file = storage.appendingPathComponent("large.bin")
        try payload.write(to: file)
        _ = try file.resourceValues(forKeys: [.fileSizeKey])
        let updated = payload + Data([3, 4, 5])
        try updated.write(to: file)
        try require(try CustomizationFiles.read(file) == updated, "Cached URL metadata affected a stable file read")
        var pieces: [Data?] = [Data([1]), Data([2, 3]), Data([4]), nil]
        let partial = try CustomizationFiles.readChunks(limit: 4) { requested in
            try require(requested > 0 && requested <= 1024 * 1024, "Unbounded file read requested")
            return pieces.removeFirst()
        }
        try require(partial == Data([1, 2, 3, 4]), "A short read was mistaken for EOF")
        try await rejects {
            _ = try CustomizationFiles.readChunks(limit: 2) { _ in Data([1, 2, 3]) }
        }
        let link = storage.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)
        try await rejects { _ = try CustomizationFiles.read(link) }
        // A real tracked installation with an empty marker must verify and uninstall.
        let poster = storage.appendingPathComponent("PosterBoard")
        let relative = "Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors/\(UUID().uuidString)"
        let target = poster.appendingPathComponent(relative)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data().write(to: target.appendingPathComponent("empty-marker"))
        let pack = WallpaperPack(id: UUID(), name: "Empty marker", descriptors: [],
                                 installations: [.init(relative: relative, files: try CustomizationFiles.tree(target), committed: true)], installedDevice: "original-device")
        _ = try makeImport(pack, storage: storage)
        let store = CustomizationStore(storage: storage, device: "original-device", resolver: { _ in poster })
        try await store.verifyWallpaperInstallation(pack.id)
        _ = try await store.removeWallpaper(pack.id)
        try require(!fm.fileExists(atPath: target.path), "Preflight still refuses tracked empty files")
    }
    static func reviewedRemoval(_ storage: URL) async throws {
        let poster = storage.appendingPathComponent("PosterBoard")
        let provider = "Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors/"
        let relative = provider + UUID().uuidString
        let target = poster.appendingPathComponent(relative)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let file = target.appendingPathComponent("Wallpaper.bin")
        let removedFile = target.appendingPathComponent("removed.bin")
        let addedFile = target.appendingPathComponent("system-cache.bin")
        try Data("installed".utf8).write(to: file)
        try Data("removed".utf8).write(to: removedFile)
        let pack = WallpaperPack(id: UUID(), name: "Reviewed", descriptors: [],
                                 installations: [.init(relative: relative, files: try CustomizationFiles.tree(target), committed: true)],
                                 installedDevice: "old-signature")
        let original = try makeImport(pack, storage: storage)
        let manifestURL = importFolder(pack, storage: storage).appendingPathComponent("Pack.plist")
        let unrelated = poster.appendingPathComponent(provider + UUID().uuidString + "/keep.bin")
        try fm.createDirectory(at: unrelated.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unrelatedBytes = Data("other wallpaper".utf8)
        try unrelatedBytes.write(to: unrelated)
        try Data("modified".utf8).write(to: file)
        try fm.removeItem(at: removedFile)
        try Data().write(to: addedFile)
        let store = CustomizationStore(storage: storage, device: "new-signature", resolver: { _ in poster })
        try await rejects { _ = try await store.removeWallpaper(pack.id) }
        let beforeReview = try CustomizationFiles.tree(poster)
        var review = try await store.reviewWallpaperRemoval(pack.id)
        let prefix = String(target.lastPathComponent.prefix(8)) + "/"
        try require(review.added == [prefix + "system-cache.bin"] && review.changed == [prefix + "Wallpaper.bin"] && review.missing == [prefix + "removed.bin"],
                    "Review did not accurately identify added, modified and missing files")
        try require(review.signingChanged, "Review omitted the changed signing identity")
        try require(try CustomizationFiles.tree(poster) == beforeReview, "Review changed system files")
        try require(try Data(contentsOf: manifestURL) == original, "Review rewrote the installation baseline")
        // Neither a made-up token nor another pack can authorize this deletion.
        try await rejects { _ = try await store.removeWallpaper(pack.id, reviewedChanges: UUID()) }
        try await rejects { _ = try await store.removeWallpaper(UUID(), reviewedChanges: review.token) }
        review = try await store.reviewWallpaperRemoval(pack.id)
        // All folders must be checked before the first deletion, including stage folders.
        let stage = target.deletingLastPathComponent().appendingPathComponent(".GestaltX-stage-" + target.lastPathComponent)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        try Data("late stage".utf8).write(to: stage.appendingPathComponent("late.bin"))
        try await rejects { _ = try await store.removeWallpaper(pack.id, reviewedChanges: review.token) }
        try require(fm.fileExists(atPath: file.path), "A stale stage review partially removed the installation")
        try fm.removeItem(at: stage)
        // A used or superseded token must not become valid when the bytes return.
        try await rejects { _ = try await store.removeWallpaper(pack.id, reviewedChanges: review.token) }
        review = try await store.reviewWallpaperRemoval(pack.id)
        let superseding = try await store.reviewWallpaperRemoval(pack.id)
        try await rejects { _ = try await store.removeWallpaper(pack.id, reviewedChanges: review.token) }
        review = superseding
        try Data("changed again".utf8).write(to: file)
        try await rejects { _ = try await store.removeWallpaper(pack.id, reviewedChanges: review.token) }
        try require(fm.fileExists(atPath: addedFile.path), "Review allowed newly changed contents to be deleted")
        review = try await store.reviewWallpaperRemoval(pack.id)
        // Local manifest changes invalidate approval even if system contents are stable.
        var plist = try PropertyListSerialization.propertyList(from: original, format: nil) as! [String: Any]
        plist["futureInstallationMetadata"] = ["version": 3]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: manifestURL)
        try await rejects { _ = try await store.removeWallpaper(pack.id, reviewedChanges: review.token) }
        try original.write(to: manifestURL)
        // No symlink may be traversed during review or during an approved removal.
        let link = target.appendingPathComponent("escape")
        try fm.createSymbolicLink(at: link, withDestinationURL: unrelated)
        try await rejects { _ = try await store.reviewWallpaperRemoval(pack.id) }
        try fm.removeItem(at: link)
        review = try await store.reviewWallpaperRemoval(pack.id)
        try fm.createSymbolicLink(at: link, withDestinationURL: unrelated)
        try await rejects { _ = try await store.removeWallpaper(pack.id, reviewedChanges: review.token) }
        try fm.removeItem(at: link)
        // Archived ownership works after the import has been removed as well.
        try await store.deleteImportedWallpaper(pack.id)
        review = try await store.reviewWallpaperRemoval(pack.id)
        _ = try await store.removeWallpaper(pack.id, reviewedChanges: review.token)
        try require(!fm.fileExists(atPath: target.path), "Reviewed, changed installation remains on disk")
        try require(try Data(contentsOf: unrelated) == unrelatedBytes, "Reviewed removal affected another wallpaper")
        let installed = try await store.listInstalledWallpapers()
        try require(installed.isEmpty, "Reviewed removal left stale installation records")
        try await rejects { _ = try await store.removeWallpaper(pack.id, reviewedChanges: review.token) }
        print("Reviewed removal passed: exact diff, unchanged review, token scope/invalidation, stage/content/manifest changes, symlinks, archived records and unrelated wallpaper preservation.")
    }
    static func links(_ storage: URL) async throws {
        let outside = storage.appendingPathComponent("Outside")
        let pack = WallpaperPack(id: UUID(), name: "Linked", descriptors: [], installedDevice: "old-device")
        let manifest = try makeImport(pack, storage: outside)
        try fm.createDirectory(at: storage.appendingPathComponent("Wallpapers"), withIntermediateDirectories: true)
        let link = importFolder(pack, storage: storage)
        try fm.createSymbolicLink(at: link, withDestinationURL: importFolder(pack, storage: outside))
        try await rejects { try await localStore(storage).deleteImportedWallpaper(pack.id) }
        try require(try Data(contentsOf: importFolder(pack, storage: outside).appendingPathComponent("Pack.plist")) == manifest, "Deletion followed a pack symlink")
        try fm.removeItem(at: link)
        _ = try makeImport(pack, storage: storage)
        try fm.createSymbolicLink(at: storage.appendingPathComponent("WallpaperInstallations"), withDestinationURL: outside)
        try await rejects { try await localStore(storage).deleteImportedWallpaper(pack.id) }
        try require(fm.fileExists(atPath: importFolder(pack, storage: storage).path), "Record-directory symlink deleted the import")
    }
}
