// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TestFaultService

// CLI for the deterministic loopback fault service (08-validation-commands.md §6).
// `serve` runs the server foreground and writes the bound port under a safe
// scratch root; Scripts/test-services.sh wraps up/health/reset/logs/down.

let arguments = CommandLine.arguments
let command = arguments.count > 1 ? arguments[1] : "serve"

/// State lives only under the build scratch directory — never a real user path.
let stateDirectory = URL(fileURLWithPath: ".build/test-services", isDirectory: true)

switch command {
case "serve":
    let requestedPort = arguments.count > 2 ? (UInt16(arguments[2]) ?? 0) : 0
    let server = FaultHTTPServer()
    do {
        let boundPort = try server.start(port: requestedPort)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try String(boundPort).write(
            to: stateDirectory.appendingPathComponent("port"),
            atomically: true, encoding: .utf8
        )
        print("PORT=\(boundPort)")
        withExtendedLifetime(server) { dispatchMain() }
    } catch {
        FileHandle.standardError.write(Data("test-services: failed to start: \(error)\n".utf8))
        exit(EXIT_FAILURE)
    }

default:
    FileHandle.standardError.write(Data("usage: test-services serve [port]\n".utf8))
    exit(EX_USAGE)
}
