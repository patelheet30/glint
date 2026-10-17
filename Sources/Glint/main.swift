import AppKit

if CommandLine.arguments.contains("--self-test") { SelfTest.run() }
if let i = CommandLine.arguments.firstIndex(of: "--render-samples"), i + 1 < CommandLine.arguments.count {
    Demo.renderSamples(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
