import Foundation

/// Serializes an in-memory `Config` to the app-managed JSONC-compatible configuration file.
/// The inverse of `ConfigLoader.load`: `ConfigLoader.load(try ConfigWriter.serialize(c)) == c` for
/// any `c`.
///
/// Comments are not preserved because the file is managed by the App. The output is strict JSON
/// (a subset of JSONC), so `JSONC.strip` re-parses it unchanged. File IO lives in the app target;
/// this type is the pure, testable serialization step.
public enum ConfigWriter {
    /// A shared encoder tuned for a clean, stable, human-diffable config file:
    /// `.prettyPrinted` (readable), `.sortedKeys` (deterministic output → tidy diffs / no churn),
    /// `.withoutEscapingSlashes` keeps URLs and application paths legible.
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// Encode `config` to JSON bytes (no trailing newline).
    public static func data(_ config: Config) throws -> Data {
        try encoder().encode(config)
    }

    /// Encode `config` to a pretty-printed JSON string, ready to write to `config.jsonc`.
    public static func serialize(_ config: Config) throws -> String {
        String(decoding: try data(config), as: UTF8.self)
    }
}
