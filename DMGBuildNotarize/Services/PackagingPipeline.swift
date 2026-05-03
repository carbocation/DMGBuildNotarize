import Foundation

struct PackagingPipeline: @unchecked Sendable {
    let validator: AppValidator
    let dmgBuilder: DmgBuilder
    let signingClient: SigningClient
    let notaryClient: NotaryClient

    init(
        runner: any ProcessRunning = ProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.validator = AppValidator(runner: runner)
        self.dmgBuilder = DmgBuilder(runner: runner, fileManager: fileManager)
        self.signingClient = SigningClient(runner: runner)
        self.notaryClient = NotaryClient(runner: runner)
    }

    func run(
        job: PackagingJob,
        onStage: @escaping @Sendable (PackagingStage) -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> PackagingResult {
        let context = try dmgBuilder.createContext(for: job)
        var submissionID: String?

        do {
            onStage(.validateApp)
            _ = try await validator.validate(appURL: job.appInfo.url, onOutput: onOutput)

            onStage(.validateNotaryProfile)
            try await notaryClient.validateKeychainProfile(job.notaryProfile, onOutput: onOutput)

            onStage(.stageVolume)
            try dmgBuilder.prepareOutput(job.outputURL, replaceExisting: job.replaceExistingOutput)
            try dmgBuilder.stageVolume(job: job, context: context)

            onStage(.createReadWriteImage)
            try await dmgBuilder.createReadWriteImage(job: job, context: context, onOutput: onOutput)

            onStage(.applyFinderLayout)
            try await dmgBuilder.applyFinderLayout(job: job, context: context, onOutput: onOutput)

            onStage(.convertCompressedImage)
            try await dmgBuilder.convertCompressedImage(context: context, onOutput: onOutput)

            onStage(.signDMG)
            try await signingClient.signDMG(job.outputURL, identity: job.signingIdentity, onOutput: onOutput)

            onStage(.notarize)
            let submission = try await notaryClient.submitAndWait(dmgURL: job.outputURL, keychainProfile: job.notaryProfile, onOutput: onOutput)
            submissionID = submission.id

            onStage(.staple)
            try await notaryClient.staple(dmgURL: job.outputURL, onOutput: onOutput)

            onStage(.verify)
            try await notaryClient.validateStaple(dmgURL: job.outputURL, onOutput: onOutput)
            try await dmgBuilder.verifyImage(job.outputURL, onOutput: onOutput)

            try? dmgBuilder.clean(context: context)
            return PackagingResult(outputURL: job.outputURL, notarizationID: submissionID)
        } catch {
            try? dmgBuilder.clean(context: context)
            throw error
        }
    }
}
