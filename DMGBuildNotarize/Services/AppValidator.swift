import Foundation

struct AppValidator: Sendable {
    let runner: any ProcessRunning

    init(runner: any ProcessRunning = ProcessRunner()) {
        self.runner = runner
    }

    func validate(appURL: URL, onOutput: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ValidationReport {
        let info = try AppBundleInfo.load(from: appURL)

        let verifyResult = try await runner.run(
            .system("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", appURL.path]),
            onOutput: onOutput
        )

        let detailsResult = try await runner.run(
            .system("/usr/bin/codesign", ["-dv", "--verbose=4", appURL.path]),
            onOutput: onOutput
        )

        let details = detailsResult.combinedOutput
        guard Self.isDistributionReadySignature(details) else {
            throw AppValidationError.notDistributionSigned(details.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let gatekeeperResult = try await runner.run(
            .system("/usr/sbin/spctl", ["-a", "-vv", "-t", "execute", appURL.path]),
            onOutput: onOutput
        )

        return ValidationReport(
            appInfo: info,
            codeSignSummary: [verifyResult.combinedOutput, details].filter { !$0.isEmpty }.joined(separator: "\n"),
            gatekeeperSummary: gatekeeperResult.combinedOutput,
            checkedAt: Date()
        )
    }

    static func isDistributionReadySignature(_ codesignDetails: String) -> Bool {
        let acceptedMarkers = [
            "Authority=Developer ID Application:",
            "Authority=Apple Mac OS Application Signing",
            "Authority=Software Signing"
        ]
        return acceptedMarkers.contains { codesignDetails.contains($0) }
    }
}

enum AppValidationError: LocalizedError, Equatable {
    case notDistributionSigned(String)

    var errorDescription: String? {
        switch self {
        case .notDistributionSigned(let details):
            if details.isEmpty {
                return "The app is signed, but not with a recognized Developer ID Application distribution certificate."
            }
            return "The app is signed, but not with a recognized Developer ID Application distribution certificate:\n\(details)"
        }
    }
}

