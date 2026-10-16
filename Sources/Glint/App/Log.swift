import os

private let logger = Logger(subsystem: "com.heetpatel.glint", category: "app")

/// Public (unredacted) log line; read with `log show --predicate 'subsystem == "com.heetpatel.glint"'`.
func log(_ message: String) { logger.notice("\(message, privacy: .public)") }
