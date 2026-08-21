import ContainerResource
import Foundation

/// Files copied into a container that had never been started.
///
/// The runtime builds a container's filesystem at start, not at create
/// (apple/container#1398, closed as intentional), so `docker cp` before start
/// has nothing to write into. The files are held here and mounted into place
/// when the container is started, one mount per file: mounting the parent
/// directory instead would hide whatever the image put there.
actor PreStartInjectionStore {
    static let shared = PreStartInjectionStore()

    struct StagedFile: Codable, Sendable {
        let guestPath: String
        let hostPath: String
    }

    private var stagingRoot: URL?
    private var autoRemove: [String: Bool] = [:]
    private var autoRemoveURL: URL?

    func configure(storageDirectory: URL) {
        stagingRoot = storageDirectory.appendingPathComponent("socktainer-prestart")
        let url = storageDirectory.appendingPathComponent("socktainer-prestart-create-options.json")
        autoRemoveURL = url
        if let data = try? Data(contentsOf: url) {
            autoRemove = (try? JSONDecoder().decode([String: Bool].self, from: data)) ?? [:]
        }
    }

    /// Remember what the container was created with, so a container rebuilt to
    /// carry these files is rebuilt the same way.
    func rememberCreateOptions(containerId: String, autoRemove remove: Bool) {
        autoRemove[containerId] = remove
        persistCreateOptions()
    }

    func createOptions(containerId: String) -> ContainerCreateOptions {
        ContainerCreateOptions(autoRemove: autoRemove[containerId] ?? false)
    }

    private func persistCreateOptions() {
        guard let autoRemoveURL else { return }
        try? JSONEncoder().encode(autoRemove).write(to: autoRemoveURL)
    }

    private func containerRoot(_ id: String) -> URL? {
        stagingRoot?.appendingPathComponent(id)
    }

    private func manifestURL(_ id: String) -> URL? {
        containerRoot(id)?.appendingPathComponent("manifest.json")
    }

    func pending(containerId: String) -> [StagedFile] {
        guard let url = manifestURL(containerId), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([StagedFile].self, from: data)) ?? []
    }

    /// The staged files as mounts, ready to be added to a container's configuration.
    func mounts(containerId: String) -> [Filesystem] {
        pending(containerId: containerId).map {
            .virtiofs(source: $0.hostPath, destination: $0.guestPath, options: [])
        }
    }

    /// Hold one uploaded file until the container is started. The staged copy
    /// mirrors the guest path, so two files never collide.
    func stage(containerId: String, guestPath: String, source: URL, mode: UInt32) throws {
        guard let root = containerRoot(containerId) else { return }
        let relative = guestPath.hasPrefix("/") ? String(guestPath.dropFirst()) : guestPath
        let destination = root.appendingPathComponent("files").appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode & 0o777)], ofItemAtPath: destination.path)

        var files = pending(containerId: containerId).filter { $0.guestPath != guestPath }
        files.append(StagedFile(guestPath: guestPath, hostPath: destination.path))
        if let manifest = manifestURL(containerId) {
            try JSONEncoder().encode(files).write(to: manifest)
        }
    }

    func clear(containerId: String) {
        if let root = containerRoot(containerId) {
            try? FileManager.default.removeItem(at: root)
        }
        if autoRemove.removeValue(forKey: containerId) != nil {
            persistCreateOptions()
        }
    }
}
