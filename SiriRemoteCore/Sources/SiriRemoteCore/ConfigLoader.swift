import Foundation

public enum ConfigError: Error, LocalizedError, Equatable {
    case parse(String)
    case validation(String)

    public var errorDescription: String? {
        switch self {
        case .parse(let message): return "Configuration syntax error: \(message)"
        case .validation(let message): return "Unsupported configuration: \(message)"
        }
    }
}

public enum ConfigLoader {
    private static let topLevelKeys: Set<String> = ["settings"]
    private static let settingKeys: Set<String> = [
        "touchEnabled", "cursorSpeed", "cursorDeadzone",
        "accelMin", "accelMax", "accelLowSpeed", "accelHighSpeed", "accelCurve",
        "clickRiseThreshold", "pressMoveMax", "circularScroll",
    ]
    private static let circularKeys: Set<String> = [
        "enabled", "minRadius", "startThreshold", "pixelsPerRadian", "scrollEase", "invert",
        "accelMin", "accelMax", "accelLowSpeed", "accelHighSpeed", "accelCurve",
    ]

    public static func load(_ jsonc: String) throws -> Config {
        let stripped = JSONC.strip(jsonc)
        let data = Data(stripped.utf8)
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: data) }
        catch { throw ConfigError.parse(error.localizedDescription) }
        try validateShape(raw)

        let config: Config
        do { config = try JSONDecoder().decode(Config.self, from: data) }
        catch { throw ConfigError.parse(error.localizedDescription) }
        try validate(config)
        return config
    }

    private static func validateShape(_ raw: Any) throws {
        guard let root = raw as? [String: Any] else {
            throw ConfigError.validation("the top level must be a JSON object")
        }
        let unknownTop = Set(root.keys).subtracting(topLevelKeys)
        guard unknownTop.isEmpty else {
            throw ConfigError.validation(
                "unknown top-level fields: \(unknownTop.sorted().joined(separator: ", "))"
            )
        }
        guard let settings = root["settings"] as? [String: Any] else {
            throw ConfigError.validation("the settings object is required")
        }
        let unknownSettings = Set(settings.keys).subtracting(settingKeys)
        guard unknownSettings.isEmpty else {
            throw ConfigError.validation(
                "unknown settings fields: \(unknownSettings.sorted().joined(separator: ", "))"
            )
        }
        if let circular = settings["circularScroll"] as? [String: Any] {
            let unknownCircular = Set(circular.keys).subtracting(circularKeys)
            guard unknownCircular.isEmpty else {
                throw ConfigError.validation(
                    "unknown circularScroll fields: \(unknownCircular.sorted().joined(separator: ", "))"
                )
            }
        }
    }

    private static func validate(_ config: Config) throws {
        let settings = config.settings
        try require(settings.cursorSpeed, in: 0.1...3.0, name: "cursorSpeed")
        try require(settings.cursorDeadzone, in: 0...0.1, name: "cursorDeadzone")
        try require(settings.accelMin, in: 0.1...5.0, name: "accelMin")
        try require(settings.accelMax, in: settings.accelMin...8.0, name: "accelMax")
        try require(settings.accelLowSpeed, in: 0...0.5, name: "accelLowSpeed")
        try require(
            settings.accelHighSpeed,
            in: settings.accelLowSpeed...1.0,
            name: "accelHighSpeed"
        )
        guard settings.accelHighSpeed > settings.accelLowSpeed else {
            throw ConfigError.validation("accelHighSpeed must be greater than accelLowSpeed")
        }
        try require(settings.accelCurve, in: 0.1...5.0, name: "accelCurve")
        try require(settings.clickRiseThreshold, in: 0...2.0, name: "clickRiseThreshold")
        try require(settings.pressMoveMax, in: 0...1.0, name: "pressMoveMax")

        let circular = settings.circularScroll
        try require(circular.minRadius, in: 0...0.71, name: "circularScroll.minRadius")
        try require(
            circular.startThreshold,
            in: 0...Double.pi,
            name: "circularScroll.startThreshold"
        )
        try require(
            circular.pixelsPerRadian,
            in: 1...1000,
            name: "circularScroll.pixelsPerRadian"
        )
        try require(circular.scrollEase, in: 0.01...1, name: "circularScroll.scrollEase")
        try require(circular.accelMin, in: 0.1...5.0, name: "circularScroll.accelMin")
        try require(
            circular.accelMax,
            in: circular.accelMin...8.0,
            name: "circularScroll.accelMax"
        )
        try require(
            circular.accelLowSpeed,
            in: 0...0.5,
            name: "circularScroll.accelLowSpeed"
        )
        try require(
            circular.accelHighSpeed,
            in: circular.accelLowSpeed...1.0,
            name: "circularScroll.accelHighSpeed"
        )
        guard circular.accelHighSpeed > circular.accelLowSpeed else {
            throw ConfigError.validation(
                "circularScroll.accelHighSpeed must be greater than accelLowSpeed"
            )
        }
        try require(circular.accelCurve, in: 0.1...5.0, name: "circularScroll.accelCurve")
    }

    private static func require(_ value: Double, in range: ClosedRange<Double>, name: String) throws {
        guard value.isFinite, range.contains(value) else {
            throw ConfigError.validation(
                "\(name) must be within \(range.lowerBound)...\(range.upperBound)"
            )
        }
    }
}
