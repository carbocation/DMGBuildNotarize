import XCTest
@testable import DMGBuildNotarize

final class DMGBuildNotarizeTests: XCTestCase {
    func testAppBundleInfoLoadsRequiredMetadata() throws {
        let appURL = try makeFixtureApp(displayName: "Fixture App", version: "1.2.3")

        let info = try AppBundleInfo.load(from: appURL)

        XCTAssertEqual(info.displayName, "Fixture App")
        XCTAssertEqual(info.bundleIdentifier, "com.example.fixture")
        XCTAssertEqual(info.shortVersion, "1.2.3")
        XCTAssertEqual(info.defaultOutputFileName, "Fixture App-1.2.3.dmg")
    }

    func testFileAndVolumeNamesAreSanitized() {
        XCTAssertEqual("Bad/Name:1".sanitizedFileComponent, "Bad-Name-1")
        XCTAssertEqual("Bad/Name:1".sanitizedVolumeName(defaultValue: "Installer"), "Bad Name 1")
        XCTAssertEqual("///".sanitizedVolumeName(defaultValue: "Installer"), "Installer")
    }

    func testSigningIdentityParserFiltersDeveloperIDApplicationIdentities() {
        let output = """
          1) ABCDEF1234567890 "Developer ID Application: Example Co (TEAMID)"
          2) 1111111111111111 "Apple Development: Example Co (TEAMID)"
             2 valid identities found
        """

        let identities = SigningClient.parseDeveloperIDApplicationIdentities(output)

        XCTAssertEqual(identities, [SigningIdentity(hash: "ABCDEF1234567890", name: "Developer ID Application: Example Co (TEAMID)")])
    }

    func testSigningIdentityExtractsTeamID() {
        XCTAssertEqual(
            SigningIdentity.extractTeamID(from: "Developer ID Application: Example Co (TEAMID1234)"),
            "TEAMID1234"
        )
        XCTAssertNil(SigningIdentity.extractTeamID(from: "Developer ID Application: Example Co"))
    }

    func testDistributionReadySignatureDetection() {
        XCTAssertTrue(AppValidator.isDistributionReadySignature("Authority=Developer ID Application: Example Co (TEAMID)"))
        XCTAssertFalse(AppValidator.isDistributionReadySignature("Authority=Apple Development: Example Co (TEAMID)"))
    }

    func testNotarySubmissionParsing() throws {
        let submission = try NotaryClient.parseSubmission("""
        {"id":"1234","status":"Accepted","message":null}
        """)

        XCTAssertEqual(submission, NotarySubmission(id: "1234", status: "Accepted", message: nil))
    }

    func testMissingNotaryProfileErrorIsActionable() {
        let result = ProcessResult(
            command: .system("/usr/bin/xcrun", ["notarytool", "submit"]),
            terminationStatus: 69,
            standardOutput: "",
            standardError: """
            Error: No Keychain password item found for profile: DeveloperID

            Run 'notarytool store-credentials' to create another credential profile.
            """
        )

        let error = NotaryClient.normalizedError(
            from: ProcessRunnerError.nonZeroExit(result),
            keychainProfile: "DeveloperID"
        )

        XCTAssertEqual(error as? NotaryError, .missingKeychainProfile("DeveloperID"))
        XCTAssertTrue(error.localizedDescription.contains("Create or validate the profile"))
        XCTAssertTrue(error.localizedDescription.contains("xcrun notarytool store-credentials 'DeveloperID' --validate"))
    }

    func testCredentialSetupBuildsAPIKeyArguments() throws {
        let request = NotaryCredentialSetupRequest(
            profileName: "DeveloperID",
            authentication: .appStoreConnectAPIKey(
                privateKeyPath: "/Users/james/AuthKey_ABC123.p8",
                keyID: "ABC123",
                issuerID: "11111111-2222-3333-4444-555555555555"
            )
        )

        XCTAssertEqual(
            try CredentialSetupService.storeCredentialsArguments(for: request),
            [
                "notarytool",
                "store-credentials",
                "DeveloperID",
                "--validate",
                "--key",
                "/Users/james/AuthKey_ABC123.p8",
                "--key-id",
                "ABC123",
                "--issuer",
                "11111111-2222-3333-4444-555555555555"
            ]
        )
    }

    func testCredentialSetupBuildsAppleIDArguments() throws {
        let request = NotaryCredentialSetupRequest(
            profileName: "DeveloperID",
            authentication: .appleID(
                appleID: "developer@example.com",
                teamID: "TEAMID1234",
                appSpecificPassword: "app-specific-password"
            )
        )

        XCTAssertEqual(
            try CredentialSetupService.storeCredentialsArguments(for: request),
            [
                "notarytool",
                "store-credentials",
                "DeveloperID",
                "--validate",
                "--apple-id",
                "developer@example.com",
                "--team-id",
                "TEAMID1234",
                "--password",
                "app-specific-password"
            ]
        )
    }

    func testCredentialSetupRemovesNewlinesFromAppSpecificPassword() throws {
        let request = NotaryCredentialSetupRequest(
            profileName: "DeveloperID",
            authentication: .appleID(
                appleID: "developer@example.com",
                teamID: "TEAMID1234",
                appSpecificPassword: "abcd-efgh\n-ijkl\r\n-mnop\n"
            )
        )

        let arguments = try CredentialSetupService.storeCredentialsArguments(for: request)

        XCTAssertEqual(arguments.last, "abcd-efgh-ijkl-mnop")
    }

    func testCredentialSetupUsesProcessRunner() async throws {
        let runner = MockProcessRunner()
        let service = CredentialSetupService(runner: runner)
        let request = NotaryCredentialSetupRequest(
            profileName: "DeveloperID",
            authentication: .appleID(
                appleID: "developer@example.com",
                teamID: "TEAMID1234",
                appSpecificPassword: "app-specific-password"
            )
        )

        let result = try await service.storeCredentials(request)

        XCTAssertEqual(result, CredentialSetupResult(profileName: "DeveloperID"))
        XCTAssertEqual(runner.commands.count, 1)
        XCTAssertEqual(runner.commands[0].executableURL.path, "/usr/bin/xcrun")
        XCTAssertEqual(
            runner.commands[0].arguments,
            [
                "notarytool",
                "store-credentials",
                "DeveloperID",
                "--validate",
                "--apple-id",
                "developer@example.com",
                "--team-id",
                "TEAMID1234",
                "--password",
                "app-specific-password"
            ]
        )
        XCTAssertEqual(runner.commands[0].timeout, 300)
    }

    func testCredentialSetupFailureDoesNotExposeAppSpecificPassword() async throws {
        let password = "abcd-efgh-ijkl-mnop"
        let command = ProcessCommand.system(
            "/usr/bin/xcrun",
            [
                "notarytool",
                "store-credentials",
                "DeveloperID",
                "--validate",
                "--apple-id",
                "developer@example.com",
                "--team-id",
                "TEAMID1234",
                "--password",
                password
            ]
        )
        let result = ProcessResult(
            command: command,
            terminationStatus: 69,
            standardOutput: "",
            standardError: "Invalid credentials."
        )
        let runner = MockProcessRunner(error: ProcessRunnerError.nonZeroExit(result))
        let service = CredentialSetupService(runner: runner)
        let request = NotaryCredentialSetupRequest(
            profileName: "DeveloperID",
            authentication: .appleID(
                appleID: "developer@example.com",
                teamID: "TEAMID1234",
                appSpecificPassword: password
            )
        )

        do {
            _ = try await service.storeCredentials(request)
            XCTFail("Expected credential setup to fail.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Invalid credentials."))
            XCTAssertFalse(error.localizedDescription.contains(password))
        }
    }

    @MainActor
    func testControllerRequiresSuccessfulValidationBeforeBuild() throws {
        let settings = makeSettings()
        let controller = PackagingController(settings: settings)
        let appURL = try makeFixtureApp(displayName: "Fixture App", version: "1.2.3")
        let info = try AppBundleInfo.load(from: appURL)

        controller.selectedAppInfo = info
        controller.outputURL = temporaryDirectory().appendingPathComponent("Fixture.dmg")

        XCTAssertFalse(controller.canBuild)

        controller.validationReport = ValidationReport(appInfo: info, codeSignSummary: "", gatekeeperSummary: "", checkedAt: Date())
        XCTAssertTrue(controller.canBuild)

        controller.isInspectingApp = true
        XCTAssertFalse(controller.canBuild)
    }

    func testNotaryProfileValidationUsesHistoryCommand() async throws {
        let runner = MockProcessRunner()
        let client = NotaryClient(runner: runner)

        try await client.validateKeychainProfile("DeveloperID")

        XCTAssertEqual(runner.commands.count, 1)
        XCTAssertEqual(runner.commands[0].executableURL.path, "/usr/bin/xcrun")
        XCTAssertEqual(
            runner.commands[0].arguments,
            ["notarytool", "history", "--keychain-profile", "DeveloperID", "--output-format", "json"]
        )
        XCTAssertEqual(runner.commands[0].timeout, 60)
    }

    func testNotaryProfileValidationRunsBeforeDmgWork() {
        let stages = PackagingStage.allCases

        XCTAssertLessThan(
            stages.firstIndex(of: .validateNotaryProfile)!,
            stages.firstIndex(of: .stageVolume)!
        )
    }

    func testDmgStagingCopiesAppAndApplicationsSymlink() throws {
        let appURL = try makeFixtureApp(displayName: "Fixture App", version: "1.2.3")
        let info = try AppBundleInfo.load(from: appURL)
        let outputURL = temporaryDirectory().appendingPathComponent("Fixture.dmg")
        let job = PackagingJob(
            appInfo: info,
            outputURL: outputURL,
            volumeName: info.defaultVolumeName,
            signingIdentity: SigningIdentity(hash: "ABC", name: "Developer ID Application: Example"),
            notaryProfile: "DeveloperID",
            replaceExistingOutput: false
        )
        let builder = DmgBuilder(runner: MockProcessRunner())
        let context = try builder.createContext(for: job)

        try builder.stageVolume(job: job, context: context)

        XCTAssertTrue(FileManager.default.fileExists(atPath: context.stagedDirectory.appendingPathComponent("Fixture.app").path))
        let applicationsLink = context.stagedDirectory.appendingPathComponent("Applications")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: applicationsLink.path), "/Applications")
        try? builder.clean(context: context)
    }

    func testFinderLayoutPositionsWindowItems() {
        let script = DmgBuilder(runner: MockProcessRunner())
            .debugFinderLayoutScript(appName: "Fixture.app", mountPath: "/tmp/Mounted Fixture")

        XCTAssertTrue(script.contains("set appItem to item \"Fixture.app\" of diskWindow"))
        XCTAssertTrue(script.contains("set applicationsItem to item \"Applications\" of diskWindow"))
        XCTAssertTrue(script.contains("set position of applicationsItem to {430, 170}"))
        XCTAssertFalse(script.contains("set position of item \"Applications\" of diskFolder"))
    }

    private func makeFixtureApp(displayName: String, version: String) throws -> URL {
        let root = temporaryDirectory()
        let appURL = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        let plist: [String: String] = [
            "CFBundleName": "Fixture",
            "CFBundleDisplayName": displayName,
            "CFBundleIdentifier": "com.example.fixture",
            "CFBundleExecutable": "Fixture",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "42"
        ]

        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let executableURL = macOSURL.appendingPathComponent("Fixture")
        try "#!/bin/sh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
        chmod(executableURL.path, 0o755)

        return appURL
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DMGBuildNotarizeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @MainActor
    private func makeSettings() -> AppSettings {
        let suiteName = "DMGBuildNotarizeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let settings = AppSettings(defaults: defaults, signingClient: SigningClient(runner: MockProcessRunner()))
        let identity = SigningIdentity(hash: "ABCDEF1234567890", name: "Developer ID Application: Example Co (TEAMID1234)")
        settings.signingIdentities = [identity]
        settings.signingIdentityHash = identity.hash
        settings.notaryProfile = "DeveloperID"
        return settings
    }
}

private final class MockProcessRunner: ProcessRunning, @unchecked Sendable {
    private(set) var commands: [ProcessCommand] = []
    var result: ProcessResult?
    var error: Error?

    init(result: ProcessResult? = nil, error: Error? = nil) {
        self.result = result
        self.error = error
    }

    func run(_ command: ProcessCommand, onOutput: @escaping @Sendable (String) -> Void) async throws -> ProcessResult {
        commands.append(command)

        if let error {
            throw error
        }

        return result ?? ProcessResult(command: command, terminationStatus: 0, standardOutput: "", standardError: "")
    }
}
