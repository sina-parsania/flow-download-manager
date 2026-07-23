// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import NativeMessaging

/// Chrome Native Messaging host entry: stdin/stdout framed JSON ↔ engine XPC.
func runNativeHost() -> Never {
    let engine = NativeHostEngineClient()
    let router = NativeMessagingRouter(engine: engine)
    let input = FileHandle.standardInput
    let output = FileHandle.standardOutput

    while true {
        let body: Data
        do {
            body = try NativeMessagingFraming.readMessage(from: input)
        } catch NativeMessagingFraming.FramingError.truncatedHeader {
            // Chrome closed the pipe — clean exit.
            exit(EXIT_SUCCESS)
        } catch {
            exit(EXIT_FAILURE)
        }

        let responseBody = router.handleSynchronously(body: body)
        do {
            try NativeMessagingFraming.writeMessage(responseBody, to: output)
        } catch {
            exit(EXIT_FAILURE)
        }
    }
}

runNativeHost()
