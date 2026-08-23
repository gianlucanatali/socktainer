import ContainerizationArchive
import ContainerizationEXT4
import Foundation
import Logging
import SystemPackage

/// Docker's copy-up: a named volume mounted over a path that exists in the image
/// starts out holding that path's contents, ownership and permissions, so an
/// image shipping a data directory owned by a non-root user can write to it.
///
/// A fresh EXT4 volume image is empty and root-owned instead, which is why an
/// image like Postgres cannot initialise its own data directory on first run.
enum VolumeCopyUp {
    /// True when the volume holds nothing but what a freshly formatted EXT4
    /// image always carries. Copy-up applies to empty volumes only — Docker
    /// leaves a volume with contents untouched.
    static func isEmpty(volumeImagePath: String) -> Bool {
        guard let reader = try? EXT4.EXT4Reader(blockDevice: FilePath(volumeImagePath)),
            let entries = try? reader.listDirectory(FilePath("/"))
        else {
            return false
        }
        return entries.allSatisfy { $0 == "." || $0 == ".." || $0 == "lost+found" }
    }

    /// Rebuilds the volume image so its root carries the subtree the image holds
    /// at `sourcePath`. A no-op when the image has nothing there.
    static func populate(
        volumeImagePath: String,
        fromRootfs rootfsPath: String,
        sourcePath: String,
        logger: Logger
    ) throws {
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath))
        let source = FilePath(sourcePath.hasPrefix("/") ? sourcePath : "/\(sourcePath)")
        guard reader.exists(source, followSymlinks: true) else { return }

        let (_, sourceInode) = try reader.stat(source)
        guard sourceInode.isDirectory else { return }

        let attributes = try FileManager.default.attributesOfItem(atPath: volumeImagePath)
        let currentSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let destination = URL(fileURLWithPath: volumeImagePath)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent("copyup-\(UUID().uuidString).img")

        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: staging) } }

        let formatter = try EXT4.Formatter(
            FilePath(staging.path),
            blockSize: 4096,
            minDiskSize: max(currentSize, 4 * 1024 * 1024)
        )
        // The mount root itself carries ownership: a directory the image gives to
        // its non-root user is unusable if only its children are copied.
        try formatter.create(
            path: FilePath("/"),
            mode: sourceInode.mode,
            uid: sourceInode.fullUid,
            gid: sourceInode.fullGid
        )
        try copyChildren(of: source, from: reader, into: formatter, at: FilePath("/"))
        try formatter.close()

        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        completed = true
        logger.debug("[volume-copyup] populated \(volumeImagePath) from \(sourcePath)")
    }

    private static func copyChildren(
        of source: FilePath,
        from reader: EXT4.EXT4Reader,
        into formatter: EXT4.Formatter,
        at target: FilePath
    ) throws {
        for name in try reader.listDirectory(source) where name != "." && name != ".." {
            let child = source.join(name)
            let childTarget = target.join(name)
            let (_, inode) = try reader.stat(child, followSymlinks: false)

            if inode.isDirectory {
                try formatter.create(
                    path: childTarget, mode: inode.mode,
                    uid: inode.fullUid, gid: inode.fullGid)
                try copyChildren(of: child, from: reader, into: formatter, at: childTarget)
            } else if inode.isSymlink {
                guard let data = try? reader.readFile(at: child, followSymlinks: false),
                    let link = String(data: data, encoding: .utf8)
                else { continue }
                try formatter.create(
                    path: childTarget, link: FilePath(link), mode: inode.mode,
                    uid: inode.fullUid, gid: inode.fullGid)
            } else if inode.isRegularFile {
                let data = try reader.readFile(at: child, followSymlinks: false)
                let contents = InputStream(data: data)
                contents.open()
                defer { contents.close() }
                try formatter.create(
                    path: childTarget, mode: inode.mode,
                    buf: contents, uid: inode.fullUid, gid: inode.fullGid)
            }
        }
    }
}
