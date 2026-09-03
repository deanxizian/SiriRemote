import Foundation

/// Product configuration for the fixed-layout SiriRemote app.
///
/// Button behavior is intentionally not configurable. Keeping the persisted model limited to
/// touch and scrolling prevents retired mapping, profile, and voice settings from silently
/// returning through hand-edited configuration files.
public struct Config: Equatable, Codable, Sendable {
    public var settings: Settings

    public init(settings: Settings = .default) {
        self.settings = settings
    }

    public struct Settings: Equatable, Codable, Sendable {
        public var touchEnabled: Bool
        public var cursorSpeed: Double
        public var cursorDeadzone: Double
        public var accelMin: Double
        public var accelMax: Double
        public var accelLowSpeed: Double
        public var accelHighSpeed: Double
        public var accelCurve: Double
        public var clickRiseThreshold: Double
        public var pressMoveMax: Double
        public var circularScroll: CircularScrollConfig

        public init(
            touchEnabled: Bool = true,
            cursorSpeed: Double = 0.6,
            cursorDeadzone: Double = 0.006,
            accelMin: Double = 0.4,
            accelMax: Double = 2.6,
            accelLowSpeed: Double = 0.008,
            accelHighSpeed: Double = 0.06,
            accelCurve: Double = 1.0,
            clickRiseThreshold: Double = 0.1,
            pressMoveMax: Double = 0.025,
            circularScroll: CircularScrollConfig = .default
        ) {
            self.touchEnabled = touchEnabled
            self.cursorSpeed = cursorSpeed
            self.cursorDeadzone = cursorDeadzone
            self.accelMin = accelMin
            self.accelMax = accelMax
            self.accelLowSpeed = accelLowSpeed
            self.accelHighSpeed = accelHighSpeed
            self.accelCurve = accelCurve
            self.clickRiseThreshold = clickRiseThreshold
            self.pressMoveMax = pressMoveMax
            self.circularScroll = circularScroll
        }

        public static let `default` = Settings()

        private enum CodingKeys: String, CodingKey {
            case touchEnabled, cursorSpeed, cursorDeadzone
            case accelMin, accelMax, accelLowSpeed, accelHighSpeed, accelCurve
            case clickRiseThreshold, pressMoveMax, circularScroll
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Settings.default
            touchEnabled = try values.decodeIfPresent(Bool.self, forKey: .touchEnabled)
                ?? defaults.touchEnabled
            cursorSpeed = try values.decodeIfPresent(Double.self, forKey: .cursorSpeed)
                ?? defaults.cursorSpeed
            cursorDeadzone = try values.decodeIfPresent(Double.self, forKey: .cursorDeadzone)
                ?? defaults.cursorDeadzone
            accelMin = try values.decodeIfPresent(Double.self, forKey: .accelMin)
                ?? defaults.accelMin
            accelMax = try values.decodeIfPresent(Double.self, forKey: .accelMax)
                ?? defaults.accelMax
            accelLowSpeed = try values.decodeIfPresent(Double.self, forKey: .accelLowSpeed)
                ?? defaults.accelLowSpeed
            accelHighSpeed = try values.decodeIfPresent(Double.self, forKey: .accelHighSpeed)
                ?? defaults.accelHighSpeed
            accelCurve = try values.decodeIfPresent(Double.self, forKey: .accelCurve)
                ?? defaults.accelCurve
            clickRiseThreshold = try values.decodeIfPresent(
                Double.self, forKey: .clickRiseThreshold
            ) ?? defaults.clickRiseThreshold
            pressMoveMax = try values.decodeIfPresent(Double.self, forKey: .pressMoveMax)
                ?? defaults.pressMoveMax
            circularScroll = try values.decodeIfPresent(
                CircularScrollConfig.self, forKey: .circularScroll
            ) ?? defaults.circularScroll
        }
    }
}

public extension Config {
    func withSettingsUpdated(_ transform: (inout Settings) -> Void) -> Config {
        var copy = self
        transform(&copy.settings)
        return copy
    }
}
