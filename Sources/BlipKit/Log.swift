import Foundation
import os

/// Shared loggers. `os.Logger` rather than `NSLog` so output is filterable with
/// `log show --predicate 'subsystem == "com.mattiapuppo.blip"'`, which is the only
/// practical way to debug an agent app with no console attached.
public enum Log {
    public static let subsystem = "com.mattiapuppo.blip"

    public static let tap = Logger(subsystem: subsystem, category: "tap")
    public static let session = Logger(subsystem: subsystem, category: "session")
    public static let scan = Logger(subsystem: subsystem, category: "scan")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
