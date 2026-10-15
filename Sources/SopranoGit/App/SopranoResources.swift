import Foundation

/// Resource lookup for the vendored Soprano chrome (RetroChrome loads the
/// Departure Mono face through `SopranoResources.bundle`). Kept under
/// Soprano's name so the vendored files compile unchanged.
enum SopranoResources {
    static let bundleName = "SopranoGit_SopranoGit.bundle"

    /// The SPM resource bundle inside the packaged app, else `Bundle.module`
    /// when running from `.build` (swift run, tests).
    static let bundle: Bundle = {
        if let url = packagedBundleURL(resourcesURL: Bundle.main.resourceURL), let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    static func packagedBundleURL(
        resourcesURL: URL?,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL? {
        guard let resourcesURL else { return nil }
        let url = resourcesURL.appendingPathComponent(bundleName, isDirectory: true)
        return fileExists(url) ? url : nil
    }
}
