// SPDX-License-Identifier: GPL-3.0-or-later

import AppIntents
import Application
import Foundation

/// Renders a refused intent as the sentence Shortcuts shows.
///
/// Without this conformance App Intents falls back to the Swift error description,
/// which is an enum case name — the same class of leak as putting `rawValue` on
/// screen. Every case of `FlowIntentFailure` carries wording written for a person.
///
/// `@retroactive` because the failure type lives in `Application`, beside the
/// validation that throws it, while App Intents is a presentation concern that
/// `Application` deliberately does not import. `Application` can never introduce
/// this conformance itself for the same reason, so the usual ambiguity risk the
/// attribute warns about does not apply here.
extension FlowIntentFailure: @retroactive CustomLocalizedStringResourceConvertible {
    public var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: message)
    }
}
