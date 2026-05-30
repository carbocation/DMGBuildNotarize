import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    @Published var signingIdentityHash: String {
        didSet { defaults.set(signingIdentityHash, forKey: Keys.signingIdentityHash) }
    }

    @Published var notaryProfile: String {
        didSet { defaults.set(notaryProfile, forKey: Keys.notaryProfile) }
    }

    @Published var defaultOutputFolderPath: String {
        didSet { defaults.set(defaultOutputFolderPath, forKey: Keys.defaultOutputFolderPath) }
    }

    @Published var signingIdentities: [SigningIdentity] = []
    @Published var identityLoadError: String?
    @Published var isLoadingIdentities = false

    private let defaults: UserDefaults
    private let signingClient: SigningClient

    init(defaults: UserDefaults = .standard, signingClient: SigningClient = SigningClient()) {
        self.defaults = defaults
        self.signingClient = signingClient
        self.signingIdentityHash = defaults.string(forKey: Keys.signingIdentityHash) ?? ""
        self.notaryProfile = defaults.string(forKey: Keys.notaryProfile) ?? "DeveloperID"
        self.defaultOutputFolderPath = defaults.string(forKey: Keys.defaultOutputFolderPath)
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    var selectedSigningIdentity: SigningIdentity? {
        signingIdentities.first { $0.hash == signingIdentityHash }
    }

    func refreshSigningIdentities() async {
        isLoadingIdentities = true
        identityLoadError = nil

        do {
            let identities = try await signingClient.loadDeveloperIDApplicationIdentities()
            signingIdentities = identities
            if signingIdentityHash.isEmpty, let first = identities.first {
                signingIdentityHash = first.hash
            }
        } catch {
            identityLoadError = error.localizedDescription
        }

        isLoadingIdentities = false
    }

    private enum Keys {
        static let signingIdentityHash = "signingIdentityHash"
        static let notaryProfile = "notaryProfile"
        static let defaultOutputFolderPath = "defaultOutputFolderPath"
    }
}
