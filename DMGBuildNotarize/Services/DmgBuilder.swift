import AppKit
import Foundation

struct DmgBuildContext: Equatable {
    let workDirectory: URL
    let stagedDirectory: URL
    let readWriteImageURL: URL
    let compressedImageURL: URL
    let finalOutputURL: URL
    let mountedVolumeURL: URL
}

struct DmgBuilder: @unchecked Sendable {
    let runner: any ProcessRunning
    let fileManager: FileManager

    init(runner: any ProcessRunning = ProcessRunner(), fileManager: FileManager = .default) {
        self.runner = runner
        self.fileManager = fileManager
    }

    func createContext(for job: PackagingJob) throws -> DmgBuildContext {
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("DMGBuildNotarize", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let volumeName = job.volumeName.sanitizedVolumeName(defaultValue: job.appInfo.defaultVolumeName)
        return DmgBuildContext(
            workDirectory: base,
            stagedDirectory: base.appendingPathComponent("stage", isDirectory: true),
            readWriteImageURL: base.appendingPathComponent("\(volumeName).rw.dmg"),
            compressedImageURL: base.appendingPathComponent(job.outputURL.lastPathComponent),
            finalOutputURL: job.outputURL,
            mountedVolumeURL: base.appendingPathComponent("mount", isDirectory: true)
        )
    }

    func prepareOutput(_ outputURL: URL, replaceExisting: Bool) throws {
        guard outputURL.hasReachableDirectoryParent else {
            throw DmgBuilderError.outputDirectoryMissing(outputURL.deletingLastPathComponent().path)
        }

        guard fileManager.fileExists(atPath: outputURL.path) else { return }
        guard replaceExisting else {
            throw DmgBuilderError.outputAlreadyExists(outputURL.path)
        }
    }

    func stageVolume(job: PackagingJob, context: DmgBuildContext) throws {
        try clean(context: context)
        try fileManager.createDirectory(at: context.stagedDirectory, withIntermediateDirectories: true)

        let appDestination = context.stagedDirectory.appendingPathComponent(job.appInfo.appFileName, isDirectory: true)
        try fileManager.copyItem(at: job.appInfo.url, to: appDestination)

        let applicationsAlias = context.stagedDirectory.appendingPathComponent("Applications")
        try fileManager.createSymbolicLink(at: applicationsAlias, withDestinationURL: URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    func createReadWriteImage(job: PackagingJob, context: DmgBuildContext, onOutput: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        try await runner.run(
            .system(
                "/usr/bin/hdiutil",
                [
                    "create",
                    "-volname", job.volumeName,
                    "-srcfolder", context.stagedDirectory.path,
                    "-ov",
                    "-format", "UDRW",
                    context.readWriteImageURL.path
                ]
            ),
            onOutput: onOutput
        )
    }

    func applyFinderLayout(job: PackagingJob, context: DmgBuildContext, onOutput: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        try fileManager.createDirectory(at: context.mountedVolumeURL, withIntermediateDirectories: true)

        do {
            try await runner.run(
                .system(
                    "/usr/bin/hdiutil",
                    [
                        "attach",
                        context.readWriteImageURL.path,
                        "-readwrite",
                        "-noverify",
                        "-noautoopen",
                        "-mountpoint",
                        context.mountedVolumeURL.path
                    ]
                ),
                onOutput: onOutput
            )

            try await runner.run(
                .system("/usr/bin/osascript", ["-e", openFinderWindowScript(mountPath: context.mountedVolumeURL.path)]),
                onOutput: onOutput
            )

            await MainActor.run {
                NSApplication.shared.activate()
            }

            try await runner.run(
                .system("/usr/bin/osascript", ["-e", finderLayoutScript(appName: job.appInfo.appFileName, mountPath: context.mountedVolumeURL.path)]),
                onOutput: onOutput
            )

            try await runner.run(.system("/usr/bin/SetFile", ["-a", "C", context.mountedVolumeURL.path]), onOutput: onOutput)
            try await runner.run(.system("/bin/sync", []), onOutput: onOutput)
        } catch {
            try? await detachMountedVolume(context: context, force: true, onOutput: onOutput)
            await activateCurrentApplication()
            throw error
        }

        try await detachMountedVolume(context: context, force: false, onOutput: onOutput)
        await activateCurrentApplication()
    }

    func convertCompressedImage(context: DmgBuildContext, onOutput: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        try await runner.run(
            .system(
                "/usr/bin/hdiutil",
                [
                    "convert",
                    context.readWriteImageURL.path,
                    "-format",
                    "UDZO",
                    "-imagekey",
                    "zlib-level=9",
                    "-o",
                    context.compressedImageURL.path
                ]
            ),
            onOutput: onOutput
        )
    }

    func verifyImage(_ dmgURL: URL, onOutput: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        try await runner.run(.system("/usr/bin/hdiutil", ["verify", dmgURL.path]), onOutput: onOutput)
    }

    func publishOutput(context: DmgBuildContext, replaceExisting: Bool) throws {
        guard context.finalOutputURL.hasReachableDirectoryParent else {
            throw DmgBuilderError.outputDirectoryMissing(context.finalOutputURL.deletingLastPathComponent().path)
        }

        guard fileManager.fileExists(atPath: context.finalOutputURL.path) else {
            try fileManager.moveItem(at: context.compressedImageURL, to: context.finalOutputURL)
            return
        }

        guard replaceExisting else {
            throw DmgBuilderError.outputAlreadyExists(context.finalOutputURL.path)
        }

        _ = try fileManager.replaceItemAt(
            context.finalOutputURL,
            withItemAt: context.compressedImageURL,
            backupItemName: nil,
            options: []
        )
    }

    func clean(context: DmgBuildContext) throws {
        if fileManager.fileExists(atPath: context.workDirectory.path) {
            try fileManager.removeItem(at: context.workDirectory)
        }
    }

    private func detachMountedVolume(context: DmgBuildContext, force: Bool, onOutput: @escaping @Sendable (String) -> Void) async throws {
        var arguments = ["detach", context.mountedVolumeURL.path]
        if force {
            arguments.append("-force")
        }
        try await runner.run(.system("/usr/bin/hdiutil", arguments), onOutput: onOutput)
    }

    private func activateCurrentApplication() async {
        await MainActor.run {
            NSApplication.shared.activate()
        }
    }

    private func openFinderWindowScript(mountPath: String) -> String {
        """
        tell application "Finder"
            set diskFolder to POSIX file \(mountPath.debugDescription) as alias
            open diskFolder
            delay 0.2
        end tell
        """
    }

    private func finderLayoutScript(appName: String, mountPath: String) -> String {
        """
        tell application "Finder"
            set diskFolder to POSIX file \(mountPath.debugDescription) as alias
            set diskWindow to container window of diskFolder
            tell diskWindow
                set current view to icon view
                set toolbar visible to false
                set statusbar visible to false
                set bounds to {100, 100, 660, 460}
            end tell
            set iconViewOptions to icon view options of diskWindow
            set arrangement of iconViewOptions to not arranged
            set icon size of iconViewOptions to 96
            set text size of iconViewOptions to 12
            set label position of iconViewOptions to bottom
            set appItem to item \(appName.debugDescription) of diskWindow
            set applicationsItem to item "Applications" of diskWindow
            set position of appItem to {180, 170}
            set position of applicationsItem to {430, 170}
            update diskFolder without registering applications
            delay 1
            close diskWindow
            delay 0.5
        end tell
        """
    }
}

#if DEBUG
extension DmgBuilder {
    func debugFinderLayoutScript(appName: String, mountPath: String) -> String {
        finderLayoutScript(appName: appName, mountPath: mountPath)
    }
}
#endif

enum DmgBuilderError: LocalizedError, Equatable {
    case outputDirectoryMissing(String)
    case outputAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .outputDirectoryMissing(let path):
            return "The output directory does not exist: \(path)"
        case .outputAlreadyExists(let path):
            return "The output file already exists: \(path)"
        }
    }
}
