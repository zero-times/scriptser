import Foundation
import os.log

/// Centralized logging for the Scriptser app using os.log
enum AppLogger {
    static let subsystem = "com.scriptser.app"

    static let general = Logger(subsystem: subsystem, category: "General")
    static let repository = Logger(subsystem: subsystem, category: "Repository")
    static let process = Logger(subsystem: subsystem, category: "Process")
    static let ui = Logger(subsystem: subsystem, category: "UI")
    static let settings = Logger(subsystem: subsystem, category: "Settings")
}

extension Logger {
    /// Log with file and line context for debugging
    func trace(
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let filename = (file as NSString).lastPathComponent
        self.debug("[\(filename):\(line)] \(function) - \(message)")
    }
}
