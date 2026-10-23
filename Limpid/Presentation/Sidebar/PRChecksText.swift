// PRChecksText.swift
// Limpid — a pull request's checks in one sentence, for the hover card and VoiceOver.

import Foundation

enum PRChecksText {
    /// One sentence shape across both forges: "<noun> <verdict>", with the
    /// count breakdown in parentheses when the forge gives us one. The noun
    /// differs per forge on purpose — see `ForgeKind.checksNoun`.
    ///
    /// GitLab reports only an aggregate status, so `counts` is absent there
    /// and the verdict stands alone. Inventing "(0/0)" would read as a
    /// confident claim about checks we never saw.
    static func make(_ checks: PRChecks, forge: ForgeKind, locale: Locale) -> String {
        // Each branch is one complete sentence in the catalog rather than
        // fragments concatenated at runtime, so a translator sees the whole
        // phrase and can reorder it.
        let noun = forge.checksNoun.resolved(in: locale)
        guard let counts = checks.counts else {
            let resource: LocalizedStringResource = switch checks.conclusion {
            case .success: "\(noun) passed"
            case .failure: "\(noun) failed"
            case .pending: "\(noun) running"
            }
            return resource.resolved(in: locale)
        }
        let resource: LocalizedStringResource = switch checks.conclusion {
        case .success: "\(noun) passed (\(counts.passed)/\(counts.total))"
        case .failure: "\(noun) failed (\(counts.passed)/\(counts.total) passed)"
        case .pending: "\(noun) running (\(counts.passed)/\(counts.total) passed)"
        }
        return resource.resolved(in: locale)
    }

    /// `make` as VoiceOver reads it: the counts in words ("Checks passed,
    /// 4 of 4" / 「チェック成功、4 件中 4 件」), since VoiceOver reads
    /// "4/4" as a date in Japanese.
    static func spoken(_ checks: PRChecks, forge: ForgeKind, locale: Locale) -> String {
        guard let counts = checks.counts else { return make(checks, forge: forge, locale: locale) }
        let noun = forge.checksNoun.resolved(in: locale)
        let resource = switch checks.conclusion {
        case .success:
            LocalizedStringResource(
                "\(noun) passed, \(counts.passed) of \(counts.total)",
                comment: "VoiceOver: a pull request's checks all passed; arguments: Checks or Pipeline, passed, total"
            )
        case .failure:
            LocalizedStringResource(
                "\(noun) failed, \(counts.passed) of \(counts.total) passed",
                comment: "VoiceOver: a pull request's checks failed; arguments: Checks or Pipeline, passed, total"
            )
        case .pending:
            LocalizedStringResource(
                "\(noun) running, \(counts.passed) of \(counts.total) passed",
                comment: "VoiceOver: a pull request's checks are running; arguments: Checks or Pipeline, passed, total"
            )
        }
        return resource.resolved(in: locale)
    }
}
