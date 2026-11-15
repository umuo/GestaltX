// SPDX-License-Identifier: GPL-3.0-only
import Foundation

actor CustomizationStore {
    private(set) var wallpaperRemovalRefreshWarning: String?
    private struct FolderSnapshot: Equatable {
        let exists: Bool
        let files: [String: String]
    }
    private struct ReviewedRemoval {
        let packID: UUID
        let sourceDigest: String
        let folders: [String: FolderSnapshot]
    }
    private var removalReviews: [UUID: ReviewedRemoval] = [:]
    private let storage: URL
    private let device: String
    private let resolver: (@Sendable (String) throws -> URL)?
    private let fm = FileManager.default
    init(storage: URL, device: String, resolver: (@Sendable (String) throws -> URL)? = nil) {
        self.storage = storage; self.device = device; self.resolver = resolver
    }
    private var wallpapers: URL { storage.appendingPathComponent("Wallpapers", isDirectory: true) }
    private func folder(_ id: UUID) -> URL { wallpapers.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func manifest(_ id: UUID) -> URL { folder(id).appendingPathComponent("Pack.plist") }
    private func log(_ message: String) {
        NotificationCenter.default.post(name: Notification.Name("GestaltX.worse_query.log"), object: nil,
                                        userInfo: ["message": message])
    }
    private func access<T>(_ identifier: String, _ operation: (URL) throws -> T) throws -> T {
        if let resolver { return try operation(resolver(identifier)) }
        #if os(iOS) && !targetEnvironment(simulator)
        guard let path = GXCustomizationAccess.container(for: identifier) else {
            throw CustomizationFailure("The device container could not be located. Read again.")
        }
        let handle = GXCustomizationAccess.acquirePath(path)
        guard handle >= 0 else { throw CustomizationFailure("These system settings are not accessible on this device.") }
        defer { worse_query_release(handle) }
        return try operation(URL(fileURLWithPath: path, isDirectory: true))
        #else
        throw CustomizationFailure("Device access is unavailable in the Simulator. Open a plist to explore GestaltX.")
        #endif
    }
    func listWallpapers() throws -> [WallpaperPack] {
        try fm.createDirectory(at: wallpapers, withIntermediateDirectories: true)
        return try fm.contentsOfDirectory(at: wallpapers, includingPropertiesForKeys: nil).compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            return try loadPack(id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    // Include ownership records retained after the imported assets were deleted.
    // Listing records never requires access to the system container.
    func listInstalledWallpapers() throws -> [WallpaperPack] {
        var byID = Dictionary(uniqueKeysWithValues: try listWallpapers().filter(\.isApplied).map { ($0.id, $0) })
        let records = try CustomizationFiles.checked("WallpaperInstallations", in: storage, missing: true)
        if fm.fileExists(atPath: records.path) {
            for url in try fm.contentsOfDirectory(at: records, includingPropertiesForKeys: nil) {
                guard url.pathExtension == "plist", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
                for data in try installationRecords(id) {
                    let pack = try decodePack(data, id: id)
                    guard pack.isApplied else { continue }
                    if var current = byID[id] {
                        let paths = Set(current.installations.map(\.relative))
                        current.installations += pack.installations.filter { !paths.contains($0.relative) }
                        byID[id] = current
                    } else {
                        byID[id] = pack
                    }
                }
            }
        }
        return byID.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }
    private func loadPack(_ id: UUID) throws -> WallpaperPack {
        try decodePack(Data(contentsOf: manifest(id)), id: id)
    }
    private func decodePack(_ data: Data, id: UUID) throws -> WallpaperPack {
        let pack = try PropertyListDecoder().decode(WallpaperPack.self, from: data)
        guard pack.id == id else { throw CustomizationFailure("The archive contains unsafe paths or links.") }
        return pack
    }
    private func savePack(_ pack: WallpaperPack) throws {
        try CustomizationFiles.saveVerified(pack, to: manifest(pack.id))
    }
    private func installationRecordsURL(_ id: UUID) throws -> URL {
        try CustomizationFiles.checked("WallpaperInstallations/\(id.uuidString).plist", in: storage, missing: true)
    }
    private func installationRecords(_ id: UUID) throws -> [Data] {
        let url = try installationRecordsURL(id)
        guard fm.fileExists(atPath: url.path) else { return [] }
        let records = try PropertyListDecoder().decode([Data].self, from: CustomizationFiles.read(url))
        for record in records { _ = try decodePack(record, id: id) }
        return records
    }
    func deleteImportedWallpaper(_ id: UUID) throws {
        let directory = try CustomizationFiles.checked("Wallpapers/\(id.uuidString)", in: storage, missing: true)
        guard fm.fileExists(atPath: directory.path) else { return }
        let data = try CustomizationFiles.read(CustomizationFiles.checked("Pack.plist", in: directory))
        let pack = try decodePack(data, id: id)
        if !pack.installations.isEmpty || pack.installedDevice != nil {
            var records = try installationRecords(id)
            if !records.contains(data) {
                // Keep complete manifests, including unknown fields and interrupted installations.
                // Multiple snapshots retain ownership if a share receipt reimports the same UUID.
                records.append(data)
                try CustomizationFiles.saveVerified(records, to: installationRecordsURL(id))
            }
            // Preserve only a small cover, not the deleted imported assets.
            // This must never require system-container access for local deletion.
            if let image = try? importedPreview(pack) {
                try? CustomizationFiles.saveVerified(image, to: previewCacheURL(id))
            }
        }
        try fm.removeItem(at: directory)
        log("Wallpapers: deleted the imported pack; applied wallpapers and installation records were kept.")
    }
    func importWallpaper(_ source: URL, id: UUID = UUID()) throws -> [WallpaperPack] {
        // Retrying a durable share receipt after interruption must not duplicate
        // an already imported pack. The library is only published when complete.
        if fm.fileExists(atPath: manifest(id).path) { _ = try loadPack(id); return try listWallpapers() }
        let temporary = fm.temporaryDirectory.appendingPathComponent("GX-Wallpaper-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try CustomizationArchive.extract(source, into: temporary)
        let descriptors = try WallpaperPackages.descriptors(in: temporary)
        let destination = folder(id)
        try fm.createDirectory(at: wallpapers, withIntermediateDirectories: true)
        let staging = wallpapers.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        var saved = false
        defer { if !saved { try? fm.removeItem(at: staging) } }
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        var pack = WallpaperPack(id: id, name: source.deletingPathExtension().lastPathComponent, descriptors: [])
        for (sourceFolder, provider) in descriptors {
            let name = UUID().uuidString
            let target = staging.appendingPathComponent(name)
            try fm.copyItem(at: sourceFolder, to: target)
            if provider != .mercury { try WallpaperPackages.randomize(target) }
            let files = try CustomizationFiles.tree(target)
            guard !files.isEmpty else { throw CustomizationFailure("This pack contains no compatible wallpapers.") }
            pack.descriptors.append(.init(folder: name, provider: provider))
            if pack.preview == nil, let image = try CustomizationImages.thumbnail(in: target) {
                try image.write(to: staging.appendingPathComponent("Preview.png"), options: .atomic)
                pack.preview = "Preview.png"
            }
        }
        try CustomizationFiles.saveVerified(pack, to: staging.appendingPathComponent("Pack.plist"))
        try fm.moveItem(at: staging, to: destination); saved = true
        log("Wallpapers: imported \(pack.descriptors.count) descriptor(s).")
        return try listWallpapers()
    }
    private func previewCacheURL(_ id: UUID) throws -> URL {
        try CustomizationFiles.checked("WallpaperPreviews/\(id.uuidString).plist", in: storage, missing: true)
    }
    private func importedPreview(_ pack: WallpaperPack) throws -> Data? {
        guard let name = pack.preview else { return nil }
        let url = try CustomizationFiles.checked(name, in: folder(pack.id))
        return try CustomizationImages.png(CustomizationFiles.read(url), size: 640)
    }
    func wallpaperPreview(_ id: UUID) throws -> Data? {
        let imported = try? loadPack(id)
        if let imported, let image = try? importedPreview(imported) { return image }
        let cache = try previewCacheURL(id)
        if fm.fileExists(atPath: cache.path),
           let data = try? PropertyListDecoder().decode(Data.self, from: CustomizationFiles.read(cache)),
           let image = try? CustomizationImages.png(data, size: 640) { return image }
        var packs = try installationRecords(id).map { try decodePack($0, id: id) }
        if let imported { packs.append(imported) }
        let owned = packs.filter { $0.installedDevice == device && $0.isApplied }
        guard !owned.isEmpty else { return nil }
        return try access("com.apple.PosterBoard") { root in
            for pack in owned {
                for entry in pack.installations where entry.committed {
                    let directory = try installationURL(entry.relative, root: root)
                    // Read only images recorded for this installation. Do not
                    // follow arbitrary files or scan unrelated system wallpapers.
                    let images = entry.files.keys.filter { ["png", "jpg", "jpeg", "heic"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
                        .sorted {
                            func priority(_ path: String) -> Int {
                                let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
                                if name.contains("thumbnail") || name.contains("preview") { return 0 }
                                if name.contains("poster") || name.contains("background") { return 1 }
                                return 2
                            }
                            let a = priority($0), b = priority($1)
                            return a == b ? $0 < $1 : a < b
                        }
                    for name in images {
                        guard let url = try? CustomizationFiles.checked(name, in: directory),
                              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 12 * 1024 * 1024,
                              let data = try? CustomizationFiles.read(url), CustomizationFiles.digest(data) == entry.files[name],
                              let image = try? CustomizationImages.png(data, size: 640) else { continue }
                        try? CustomizationFiles.saveVerified(image, to: previewCacheURL(id))
                        return image
                    }
                }
            }
            return nil
        }
    }
    private func stageURL(_ relative: String, root: URL) throws -> URL {
        let target = try installationURL(relative, root: root)
        return target.deletingLastPathComponent().appendingPathComponent(".GestaltX-stage-\(target.lastPathComponent)")
    }
    private func installationURL(_ relative: String, root: URL) throws -> URL {
        let pieces = relative.split(separator: "/").map(String.init)
        guard pieces.count == 8, Array(pieces[0...2]) == ["Library", "Application Support", "PRBPosterExtensionDataStore"],
              Int(pieces[3]) != nil, pieces[4] == "Extensions", pieces[6] == "descriptors",
              WallpaperProvider.collections.identifiers.contains(pieces[5]) || WallpaperProvider.mercury.identifiers.contains(pieces[5]) || WallpaperProvider.video.identifiers.contains(pieces[5]),
              UUID(uuidString: pieces[7]) != nil else { throw CustomizationFailure("The archive contains unsafe paths or links.") }
        return try CustomizationFiles.checked(relative, in: root, missing: true)
    }
    private func removeInstallation(_ entry: WallpaperInstallation, root: URL) throws {
        for url in [try installationURL(entry.relative, root: root), try stageURL(entry.relative, root: root)] {
            guard fm.fileExists(atPath: url.path) else { continue }
            let actual = try CustomizationFiles.tree(url)
            guard actual.allSatisfy({ entry.files[$0.key] == $0.value }),
                  !entry.committed || actual == entry.files else {
                throw CustomizationFailure("Wallpaper files differ from the installation record. Review Changes before removal.")
            }
            try fm.removeItem(at: url)
            guard !fm.fileExists(atPath: url.path) else {
                throw CustomizationFailure("Could not remove wallpaper files.")
            }
        }
    }
    func applyWallpaper(_ id: UUID) throws -> [WallpaperPack] {
        var pack = try loadPack(id)
        guard pack.installations.isEmpty else { return try listWallpapers() }
        pack.installedDevice = device
        try access("com.apple.PosterBoard") { root in
            do {
                for descriptor in pack.descriptors {
                    guard UUID(uuidString: descriptor.folder) != nil else { throw CustomizationFailure("The archive contains unsafe paths or links.") }
                    let source = try CustomizationFiles.checked(descriptor.folder, in: folder(id))
                    let hashes = try CustomizationFiles.tree(source)
                    for providerPath in try WallpaperPackages.providerPaths(in: root, provider: descriptor.provider) {
                        let relative = providerPath + "/" + UUID().uuidString
                        let target = try installationURL(relative, root: root)
                        let stage = try stageURL(relative, root: root)
                        guard !fm.fileExists(atPath: target.path), !fm.fileExists(atPath: stage.path) else {
                            throw CustomizationFailure("The files changed. Read again before applying.")
                        }
                        // Persist ownership before touching the device, including interrupted copies.
                        pack.installations.append(.init(relative: relative, files: hashes))
                        try savePack(pack)
                        try fm.copyItem(at: source, to: stage)
                        guard try CustomizationFiles.tree(stage) == hashes else {
                            throw CustomizationFailure("The files changed. Read again before applying.")
                        }
                        try fm.moveItem(at: stage, to: target)
                        pack.installations[pack.installations.count-1].committed = true
                        try savePack(pack)
                    }
                }
                try refreshPosterBoard(root)
            } catch {
                let originalError = error
                var remaining: [WallpaperInstallation] = []
                for entry in pack.installations {
                    do { try removeInstallation(entry, root: root) } catch { remaining.append(entry) }
                }
                pack.installations = remaining
                try savePack(pack)
                if !remaining.isEmpty { throw CustomizationFailure("Some files could not be restored. The backup has been kept.") }
                throw originalError
            }
        }
        log("Wallpapers: installed and verified \(pack.installations.count) descriptor folder(s).")
        return try listWallpapers()
    }
    private func refreshPosterBoard(_ root: URL) throws {
        let path = "Library/Preferences/com.apple.PosterBoard.unprotectedUserDefaults.plist"
        let url = try CustomizationFiles.checked(path, in: root, missing: true)
        var values: [String: Any] = [:]
        var before = CustomizationOriginal(data: nil)
        if fm.fileExists(atPath: url.path) {
            let data = try CustomizationFiles.read(url)
            guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw CustomizationFailure("The files changed. Read again before applying.")
            }
            values = dictionary; before = .init(data: data)
        }
        // Gester's refresh flag, merged into existing preferences instead of replacing them.
        values["PBF_RESET_FILE_PROTECTIONS"] = true
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        let session = CustomizationFiles.digest(Data(device.utf8))
        let writer = CustomizationFileTransaction(root: root,
            storage: storage.appendingPathComponent("PosterBoardDefaults/\(session)"), device: device)
        try writer.replace([path: data], expected: [path: before])
    }
    // Re-signing can change identifierForVendor. Never adopt changed system
    // contents as the new baseline: verify all recorded bytes first, then update
    // only the local binding, preserving unknown manifest fields atomically.
    func verifyWallpaperInstallation(_ id: UUID) throws {
        let importedPath = "Wallpapers/\(id.uuidString)/Pack.plist"
        let importedURL = try CustomizationFiles.checked(importedPath, in: storage, missing: true)
        let importedData = fm.fileExists(atPath: importedURL.path) ? try CustomizationFiles.read(importedURL) : nil
        let archivedURL = try installationRecordsURL(id)
        let archivedOriginal = fm.fileExists(atPath: archivedURL.path) ? try CustomizationFiles.read(archivedURL) : nil
        let archived = try archivedOriginal.map { try PropertyListDecoder().decode([Data].self, from: $0) } ?? []
        let snapshots = archived + (importedData.map { [$0] } ?? [])
        let packs = try snapshots.map { try decodePack($0, id: id) }
        guard packs.contains(where: \.isApplied) else {
            throw CustomizationFailure("No matching installed wallpaper was found. Installation records were kept.")
        }
        try access("com.apple.PosterBoard") { root in
            var matched = false
            for pack in packs {
                for entry in pack.installations {
                    for url in [try installationURL(entry.relative, root: root), try stageURL(entry.relative, root: root)] {
                        guard fm.fileExists(atPath: url.path) else { continue }
                        guard try CustomizationFiles.tree(url) == entry.files else {
                            throw CustomizationFailure("Wallpaper files differ from the installation record. Review Changes before removal.")
                        }
                        matched = true
                    }
                }
            }
            guard matched else {
                throw CustomizationFailure("No matching installed wallpaper was found. Installation records were kept.")
            }
        }
        func rebound(_ data: Data) throws -> Data {
            let pack = try decodePack(data, id: id)
            guard pack.isApplied else { return data }
            guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw CustomizationFailure("The files changed. Read again before applying.")
            }
            plist["installedDevice"] = device
            return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        }
        var changes: [String: Data] = [:]
        var expected: [String: CustomizationOriginal] = [:]
        if let importedData {
            changes[importedPath] = try rebound(importedData)
            expected[importedPath] = .init(data: importedData)
        }
        if !archived.isEmpty {
            let recordsPath = "WallpaperInstallations/\(id.uuidString).plist"
            changes[recordsPath] = try PropertyListEncoder().encode(archived.map { try rebound($0) })
            expected[recordsPath] = .init(data: archivedOriginal)
        }
        let session = CustomizationFiles.digest(Data(device.utf8))
        try CustomizationFileTransaction(root: storage,
            storage: storage.appendingPathComponent("WallpaperVerification/\(session)"), device: device)
            .replace(changes, expected: expected)
        log("Wallpapers: verified tracked system contents and refreshed the local installation binding; no system wallpaper was changed.")
    }
    private func removalSources(_ id: UUID) throws -> [Data] {
        var sources = try installationRecords(id)
        let url = try CustomizationFiles.checked("Wallpapers/\(id.uuidString)/Pack.plist", in: storage, missing: true)
        if fm.fileExists(atPath: url.path) { sources.append(try CustomizationFiles.read(url)) }
        return sources
    }
    private func sourceDigest(_ sources: [Data]) -> String {
        CustomizationFiles.digest(Data(sources.map { CustomizationFiles.digest($0) }.joined(separator: "|").utf8))
    }
    private func removalFolders(_ entry: WallpaperInstallation, root: URL) throws -> [(String, URL)] {
        [(entry.relative, try installationURL(entry.relative, root: root)),
         (entry.relative + "#stage", try stageURL(entry.relative, root: root))]
    }
    func reviewWallpaperRemoval(_ id: UUID) throws -> WallpaperRemovalReview {
        let sources = try removalSources(id)
        let packs = try sources.map { try decodePack($0, id: id) }
        guard packs.contains(where: \.isApplied) else { throw CocoaError(.fileReadNoSuchFile) }
        var folders: [String: FolderSnapshot] = [:]
        var added = Set<String>(), changed = Set<String>(), missing = Set<String>()
        try access("com.apple.PosterBoard") { root in
            for pack in packs {
                for entry in pack.installations {
                    for (key, url) in try removalFolders(entry, root: root) {
                        let exists = fm.fileExists(atPath: url.path)
                        let files = exists ? try CustomizationFiles.tree(url) : [:]
                        folders[key] = .init(exists: exists, files: files)
                        // Absent staging folders are normal after a committed install.
                        if key.hasSuffix("#stage") && !exists { continue }
                        let label = String(URL(fileURLWithPath: entry.relative).lastPathComponent.prefix(8)) + (key.hasSuffix("#stage") ? " (stage)/" : "/")
                        for file in files.keys where entry.files[file] == nil { added.insert(label + file) }
                        for file in entry.files.keys {
                            if files[file] == nil { missing.insert(label + file) }
                            else if files[file] != entry.files[file] { changed.insert(label + file) }
                        }
                    }
                }
            }
        }
        let token = UUID()
        // Only the actor retains the authority-bearing snapshot; the UI receives
        // a one-use token and a display-only diff, never arbitrary delete paths.
        removalReviews = removalReviews.filter { $0.value.packID != id }
        removalReviews[token] = .init(packID: id, sourceDigest: sourceDigest(sources), folders: folders)
        return .init(token: token, added: added.sorted(), changed: changed.sorted(), missing: missing.sorted(),
                     signingChanged: packs.contains { $0.isApplied && $0.installedDevice != device })
    }
    func removeWallpaper(_ id: UUID, reviewedChanges token: UUID? = nil) throws -> [WallpaperPack] {
        wallpaperRemovalRefreshWarning = nil
        var approval: ReviewedRemoval?
        if let token {
            guard let saved = removalReviews.removeValue(forKey: token), saved.packID == id,
                  saved.sourceDigest == sourceDigest(try removalSources(id)) else {
                throw CustomizationFailure("Wallpaper changed since review. Review the changes again.")
            }
            approval = saved
        }
        let directory = try CustomizationFiles.checked("Wallpapers/\(id.uuidString)", in: storage, missing: true)
        let hasImport = fm.fileExists(atPath: directory.path)
        let imported = hasImport ? try loadPack(id) : nil
        var packs = try installationRecords(id).map { try decodePack($0, id: id) }
        if let imported { packs.append(imported) }
        guard !packs.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        var installations: [WallpaperInstallation] = []
        for pack in packs where !pack.installations.isEmpty {
            guard pack.installedDevice == device || approval != nil else {
                // A prior attempt may have removed the directories and then
                // failed during gallery refresh. Clearing only an obsolete local
                // record does not require adopting another device's installation.
                let stillExists = try access("com.apple.PosterBoard") { root in
                    try pack.installations.contains { entry in
                        let target = try installationURL(entry.relative, root: root)
                        let stage = try stageURL(entry.relative, root: root)
                        return fm.fileExists(atPath: target.path) || fm.fileExists(atPath: stage.path)
                    }
                }
                if stillExists {
                    throw CustomizationFailure("Installation records need verification. Use Verify Installation before removing this wallpaper.")
                }
                continue
            }
            for entry in pack.installations {
                if let index = installations.firstIndex(where: { $0.relative == entry.relative }) {
                    guard installations[index].files == entry.files else {
                        throw CustomizationFailure("Wallpaper files differ from the installation record. Review Changes before removal.")
                    }
                    installations[index].committed = installations[index].committed || entry.committed
                } else {
                    installations.append(entry)
                }
            }
        }
        if !installations.isEmpty {
            try access("com.apple.PosterBoard") { root in
                // Validate every installed folder before deleting the first one.
                var hadFiles = false
                do {
                    for entry in installations {
                        for (key, url) in try removalFolders(entry, root: root) {
                            let exists = fm.fileExists(atPath: url.path)
                            let actual = exists ? try CustomizationFiles.tree(url) : [:]
                            if let approval {
                                guard approval.folders[key] == FolderSnapshot(exists: exists, files: actual) else {
                                    throw CustomizationFailure("Wallpaper changed since review. Review the changes again.")
                                }
                            } else if exists, !(actual.allSatisfy({ entry.files[$0.key] == $0.value }) && (!entry.committed || actual == entry.files)) {
                                throw CustomizationFailure("Wallpaper files differ from the installation record. Review Changes before removal.")
                            }
                            hadFiles = hadFiles || exists
                        }
                    }
                } catch {
                    throw wallpaperOperationError(L("Could not verify wallpaper files before removal."), underlying: error)
                }
                for entry in installations {
                    do {
                        if let approval {
                            for (key, url) in try removalFolders(entry, root: root) {
                                guard let snapshot = approval.folders[key] else {
                                    throw CustomizationFailure("Wallpaper changed since review. Review the changes again.")
                                }
                                let exists = fm.fileExists(atPath: url.path)
                                let actual = exists ? try CustomizationFiles.tree(url) : [:]
                                guard snapshot == FolderSnapshot(exists: exists, files: actual) else {
                                    throw CustomizationFailure("Wallpaper changed since review. Review the changes again.")
                                }
                                if exists {
                                    try fm.removeItem(at: url)
                                    guard !fm.fileExists(atPath: url.path) else { throw CustomizationFailure("Could not remove wallpaper files.") }
                                }
                            }
                        } else { try removeInstallation(entry, root: root) }
                    }
                    catch {
                        throw wallpaperOperationError(L("Could not remove wallpaper files."), underlying: error)
                    }
                }
                // Removing the authoritative directories and refreshing the cached
                // gallery are separate outcomes. A refresh error must not report
                // that verified, completed file deletion failed.
                do { if hadFiles { try refreshPosterBoard(root) } }
                catch {
                    wallpaperRemovalRefreshWarning = error.localizedDescription
                    let ns = error as NSError
                    log("Wallpapers: tracked files removed; gallery refresh failed (\(ns.domain): \(ns.code)).")
                }
            }
        }
        do {
            if var pack = imported {
                pack.installations = []
                try savePack(pack)
            }
            let recordsURL = try installationRecordsURL(id)
            if fm.fileExists(atPath: recordsURL.path) { try fm.removeItem(at: recordsURL) }
            if let cache = try? previewCacheURL(id), fm.fileExists(atPath: cache.path) { try? fm.removeItem(at: cache) }
            if hasImport { try fm.removeItem(at: directory) }
        } catch {
            throw wallpaperOperationError(L("Wallpaper files were removed, but installation record cleanup failed. Try removing this entry again."), underlying: error)
        }
        log("Wallpapers: removed only this pack's tracked additions.")
        return try listWallpapers()
    }
    private func wallpaperOperationError(_ message: String, underlying: Error) -> NSError {
        let error = underlying as NSError
        return NSError(domain: "GestaltX.WallpaperRemoval", code: error.code, userInfo: [
            NSLocalizedDescriptionKey: message + "\n" + error.localizedDescription + "\n(\(error.domain): \(error.code))",
            NSUnderlyingErrorKey: underlying,
        ])
    }
}
