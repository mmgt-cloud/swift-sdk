import Foundation

/// Accepts RFC 3339 timestamps with whole seconds or fractional seconds, including Go's RFC3339Nano output.
public enum WireDate {
  public static func parse(_ value: String) throws -> Date {
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = format.date(from: value) { return date }
    format.formatOptions = [.withInternetDateTime]
    guard let date = format.date(from: value) else {
      throw MMGTError.invalidResponse("Invalid RFC 3339 timestamp")
    }
    return date
  }
}
