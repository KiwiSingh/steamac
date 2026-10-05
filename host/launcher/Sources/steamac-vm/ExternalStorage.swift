import Foundation

/// Resolve the real mounted volume, including symlinked parents and missing destination folders.
enum ExternalStorage {
    static func volume(forPath path: String) -> URL? {
        guard !path.isEmpty, (path as NSString).isAbsolutePath else { return nil }
        let fm = FileManager.default
        var ancestor = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        while !fm.fileExists(atPath: ancestor.path) && ancestor.path != "/" {
            ancestor.deleteLastPathComponent()
            ancestor = ancestor.resolvingSymlinksInPath()
        }
        ancestor = ancestor.resolvingSymlinksInPath()
        guard let values = try? ancestor.resourceValues(forKeys: [.volumeURLKey, .volumeIsInternalKey,
                                                                 .volumeIsLocalKey, .volumeIsReadOnlyKey]),
              let volume = values.volume, values.volumeIsInternal == false,
              values.volumeIsLocal == true, values.volumeIsReadOnly == false,
              volume.path.hasPrefix("/Volumes/"), fm.isWritableFile(atPath: volume.path),
              fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [])?.contains(where: {
                  $0.standardizedFileURL.path == volume.standardizedFileURL.path
              }) == true else { return nil }
        return volume
    }

    static var volumes: [URL] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [])
            .filter { volume(forPath: $0.path) != nil }.sorted { $0.path < $1.path }
    }

    static func cacheRoot(forDisk path: String) -> String? {
        volume(forPath: path)?.appendingPathComponent("steamac/cache").path
    }
}
