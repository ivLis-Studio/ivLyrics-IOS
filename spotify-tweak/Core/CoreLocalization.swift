import Foundation

// Models.swift also defines the standalone app's AppStatus.text(settings:).
// Compile that original file unchanged without bringing the app's settings,
// singleton services, resources or lifecycle into the host process. The core
// does not use AppStatus; a caller can supply localization if it later does.
struct CoreLocalization {
    let translate: (String) -> String
    func t(_ key: String) -> String { translate(key) }
}

typealias AppSettings = CoreLocalization
