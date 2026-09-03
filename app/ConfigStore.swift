//
//  ConfigStore.swift
//  SiriRemote
//
//  Product-level configuration boundary. The fixed button layout is code-owned; only touch and
//  circular-scroll preferences are persisted.
//

import Foundation

enum ConfigStore {
    enum ProductError: LocalizedError {
        case invalidFile(String)

        var errorDescription: String? {
            switch self {
            case .invalidFile(let detail):
                return L("Configuration file could not be read: %@", detail)
            }
        }
    }

    static private(set) var lastLoadError: String?

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SiriRemote", isDirectory: true)
    }

    static var path: URL {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory.appendingPathComponent("config.jsonc")
    }

    static func loadOrBootstrapText() -> String {
        if let text = try? String(contentsOf: path, encoding: .utf8) {
            if isRetiredSchemaConfig(text) {
                do {
                    let archived = try archiveRetiredConfig()
                    try writeDefaultTemplate()
                    NSLog("[SiriRemote] archived retired configuration at \(archived.path)")
                    return defaultTemplate
                } catch {
                    NSLog("[SiriRemote] could not archive retired configuration: \(error)")
                }
            }
            return text
        }
        try? writeDefaultTemplate()
        return defaultTemplate
    }

    static func loadConfig() -> Config {
        do {
            let config = try loadAndValidate(loadOrBootstrapText())
            lastLoadError = nil
            return config
        } catch {
            lastLoadError = error.localizedDescription
            NSLog("[SiriRemote] config rejected: \(error.localizedDescription)")
            return (try? loadAndValidate(defaultTemplate)) ?? Config()
        }
    }

    static func loadAndValidate(_ text: String) throws -> Config {
        do {
            return try ConfigLoader.load(text)
        } catch {
            throw ProductError.invalidFile(error.localizedDescription)
        }
    }

    static func save(_ config: Config) throws {
        let serialized = try ConfigWriter.serialize(config)
        _ = try ConfigLoader.load(serialized)
        if let existing = try? String(contentsOf: path, encoding: .utf8) {
            let backup = path.appendingPathExtension("bak")
            try? Data(existing.utf8).write(to: backup)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: backup.path
            )
        }
        try serialized.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    /// Mapping/profile builds used additional top-level objects and settings. They are deliberately
    /// not migrated: preserve the old file, then start from the small first-release schema.
    private static func isRetiredSchemaConfig(_ text: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(JSONC.strip(text).utf8)),
              let root = object as? [String: Any] else { return false }
        if Set(root.keys) != Set(["settings"]) { return true }
        guard let settings = root["settings"] as? [String: Any] else { return false }
        let retired = ["defaultMode", "doubaoInputSourceID", "holdThreshold", "doubleTapWindow"]
        return retired.contains { settings[$0] != nil }
    }

    private static func archiveRetiredConfig() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var archive = directory.appendingPathComponent(
            "config.retired-\(formatter.string(from: Date())).jsonc"
        )
        if FileManager.default.fileExists(atPath: archive.path) {
            archive = directory.appendingPathComponent(
                "config.retired-\(UUID().uuidString.lowercased()).jsonc"
            )
        }
        try FileManager.default.moveItem(at: path, to: archive)
        return archive
    }

    private static func writeDefaultTemplate() throws {
        try defaultTemplate.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    static let defaultTemplate = """
    {
      "settings": {
        "touchEnabled": true,
        "cursorSpeed": 0.6,
        "cursorDeadzone": 0.006,
        "accelMin": 0.4,
        "accelMax": 2.6,
        "accelLowSpeed": 0.008,
        "accelHighSpeed": 0.06,
        "accelCurve": 1.0,
        "clickRiseThreshold": 0.1,
        "pressMoveMax": 0.025,
        "circularScroll": {
          "enabled": true,
          "minRadius": 0.35,
          "startThreshold": 0.35,
          "pixelsPerRadian": 75,
          "scrollEase": 0.3,
          "invert": false
        }
      }
    }
    """
}
