import Foundation

enum PackagingStage: String, CaseIterable, Identifiable {
    case validateApp
    case validateNotaryProfile
    case stageVolume
    case createReadWriteImage
    case applyFinderLayout
    case convertCompressedImage
    case signDMG
    case notarize
    case staple
    case verify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .validateApp: return "Validate app"
        case .validateNotaryProfile: return "Validate notary profile"
        case .stageVolume: return "Stage installer"
        case .createReadWriteImage: return "Create writable DMG"
        case .applyFinderLayout: return "Apply Finder layout"
        case .convertCompressedImage: return "Compress DMG"
        case .signDMG: return "Sign DMG"
        case .notarize: return "Notarize"
        case .staple: return "Staple ticket"
        case .verify: return "Verify"
        }
    }
}

enum StageState: Equatable {
    case pending
    case running
    case succeeded
    case failed(String)
}

struct StageProgress: Identifiable, Equatable {
    let stage: PackagingStage
    var state: StageState

    var id: PackagingStage { stage }
}
