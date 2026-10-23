// DemoFixture+Transcripts.swift
// Limpid — what each demo pane prints: an agent's conversation or a shell's output, the same on every run.

import Foundation

// Each pane types one command line that prints its scene. We draw the
// scenes rather than run real tools: demo machines may not have them, their
// output drifts with every release, and an agent would need an account.
//
// The text goes through `printf '%b'`, with its colors written as the
// characters `\033[...m`: the line is typed into the shell as input, and an
// escape character itself would reach zsh's line editor as a key. Colors
// name the 16-color palette (dim, cyan, green, red) so they follow the
// theme. An agent's scene ends by hiding the cursor and waiting in `read`,
// so no shell prompt shows under the agent's screen and no blinking cursor
// makes two captures differ; the shell stays the pane's process, which the
// screenshot script checks the working directory of. The wait keeps echo on
// (`read -r`, not `read -rs`): a terminal with echo off is taking a
// password, and Ghostty marks it with a lock after the last line. When the
// wait ends (someone presses Return in a pane they opened), the cursor comes
// back for the prompt that follows.
//
// Each command first sets a neutral prompt (assignments with no command word
// change the live shell): a pane that ends at its prompt would otherwise
// show the demo machine's own `user@host` from the person's shell
// configuration. `PS1` comes first and `PROMPT` last because zsh treats the
// two as one parameter and keeps the later assignment, so zsh reads
// `PROMPT`, where `%%` is a percent sign, and bash reads `PS1`, where `\$`
// is a dollar sign; each form would show its escape literally in the other.
// Lines are at most 70 columns, which the hero's 104-column terminal holds.

extension DemoFixture {
    /// How a line is drawn, as the SGR parameter of its color.
    enum Ink: String {
        case plain = "0"
        case dim = "2"
        case accent = "36"
        case success = "32"
        case failure = "31"
    }

    /// One line of a pane's scene.
    struct Line: Equatable {
        let ink: Ink
        let text: String

        init(_ ink: Ink = .plain, _ text: String = "") {
            self.ink = ink
            self.text = text
        }
    }

    /// Whether a scene ends at the shell's prompt or holds the screen, as an
    /// agent still in front of the pane would.
    enum SceneEnd {
        case prompt
        case holdsScreen
    }

    /// The command that prints `lines` in a pane whose prompt reads `prompt`.
    /// Given a `title`, the scene first sets the terminal's title to it, as
    /// an agent sets it to its conversation's: the tab's title is the
    /// terminal's, and the shell's own report of its folder would otherwise
    /// stand. Scenes that hold the screen pass one. Scenes that end at the
    /// prompt pass none, as their shell reports its folder again there; the
    /// stopped agent's tab then reads its folder, as a real one whose agent
    /// has left does.
    static func scene(_ lines: [Line], prompt: String, end: SceneEnd, title: String? = nil) -> String {
        let body = lines.map(encoded).joined(separator: "\\n")
        var reset = "PS1='\(prompt) \\$ ' PROMPT='\(prompt) %% ' && clear"
        if let title {
            reset += " && printf '\\033]2;%s\\007' '\(title.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        switch end {
        case .prompt where lines.isEmpty:
            return reset
        case .prompt:
            return "\(reset) && printf '%b\\n' '\(body)'"
        case .holdsScreen:
            return "\(reset) && printf '\\033[?25l%b' '\(body)' && read -r; printf '\\033[?25h'"
        }
    }

    /// A line as `%b` reads it inside single quotes: a backslash doubled, a
    /// quote closed, escaped, and opened again, and the color around it.
    private static func encoded(_ line: Line) -> String {
        let text = line.text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "'\\''")
        guard line.ink != .plain, !text.isEmpty else { return text }
        return "\\033[\(line.ink.rawValue)m\(text)\\033[0m"
    }

    /// The command each pane runs as it opens. A shell with nothing to
    /// show opens at its prompt in its folder.
    static func transcript(for slot: Slot) -> String {
        if let prompt = emptyShellPrompts[slot] {
            return scene([], prompt: prompt, end: .prompt)
        }
        let title = conversationTitle(of: slot)
        return switch slot {
        case .reminders: scene(remindersScreen, prompt: "duesmith-feat-overdue-reminders", end: .holdsScreen, title: title)
        case .remindersCodex: scene(remindersCodexScreen, prompt: "duesmith-feat-overdue-reminders", end: .holdsScreen, title: title)
        case .dev: scene(devScreen, prompt: "duesmith-feat-overdue-reminders", end: .holdsScreen, title: "dev")
        case .git: scene(gitLog, prompt: "duesmith-feat-overdue-reminders", end: .prompt)
        case .prReview: scene(prReviewScreen, prompt: "duesmith", end: .holdsScreen, title: title)
        case .taxRounding: scene(taxRoundingScreen, prompt: "duesmith-fix-tax-rounding", end: .holdsScreen, title: title)
        case .proration: scene(prorationScreen, prompt: "duesmith-feat-proration", end: .holdsScreen, title: title)
        case .webhook: scene(webhookScreen, prompt: "duesmith-fix-webhook-timeout", end: .prompt)
        case .docs: scene(docsScreen, prompt: "duesmith-docs-invoices-api", end: .holdsScreen, title: title)
        case .pageBreaks: scene(pageBreaksScreen, prompt: "pdf-worker-fix-page-breaks", end: .holdsScreen, title: title)
        case .batchRender: scene(batchRenderScreen, prompt: "pdf-worker-feat-batch-render", end: .holdsScreen, title: title)
        case .pdfMain, .dotfiles, .scratch: scene([], prompt: "", end: .prompt)
        }
    }

    /// The prompts of the shells that print no scene.
    private static let emptyShellPrompts: [Slot: String] = [.pdfMain: "pdf-worker", .dotfiles: "dotfiles", .scratch: "~"]

    // MARK: - The selected workspace

    /// Claude's screen in "Send overdue invoice reminders": the end of T4,
    /// whose tests failed, then all of T5, which fixed them. The changes it
    /// names are the staged turns' (`conversations`): T4 changed
    /// ReminderSettings.tsx (+41) and BillingPage.tsx (+6 −9), T5
    /// selectOverdue.ts (+31 −4) and its test (+58).
    static var remindersScreen: [Line] {
        [
            Line(.dim, "⏺ Write(apps/web/src/billing/ReminderSettings.tsx)"),
            Line(.dim, "  ⎿  Wrote 41 lines"),
            Line(),
            Line(.dim, "⏺ Update(apps/web/src/billing/BillingPage.tsx)"),
            Line(.dim, "  ⎿  Updated with 6 additions and 9 removals"),
            Line(),
            Line(.dim, "⏺ Bash(pnpm test src/reminders)"),
            Line(.dim, "  ⎿  ✗ 2 failed, 11 passed (src/reminders)"),
            Line(.dim, "⏺ The settings save, but a paid invoice still gets a reminder,"),
            Line(.dim, "  so two tests fail. I'll fix that in the next turn."),
            Line(.dim, "✻ Worked for 11m 2s"),
            Line(),
            Line(.plain, "> \(remindersLastPrompt)"),
            Line(),
            Line(.accent, "⏺ Read(apps/api/src/reminders/selectOverdue.ts)"),
            Line(.dim, "  ⎿  Read 64 lines"),
            Line(),
            Line(.accent, "⏺ Update(apps/api/src/reminders/selectOverdue.ts)"),
            Line(.dim, "  ⎿  Updated with 31 additions and 4 removals"),
            Line(),
            Line(.accent, "⏺ Write(apps/api/src/reminders/selectOverdue.test.ts)"),
            Line(.dim, "  ⎿  Wrote 58 lines"),
            Line(),
            Line(.accent, "⏺ Bash(pnpm test src/reminders)"),
            Line(.success, "  ⎿  ✓ 16 passed (src/reminders)"),
            Line(),
            Line(.plain, "⏺ Reminders now go only to invoices that are still open past their"),
            Line(.plain, "  due date. Paid, voided, and disputed invoices are skipped, and a"),
            Line(.plain, "  payment that arrives after the job starts cancels the reminder"),
            Line(.plain, "  before it is sent. INV-1042 ($1,240.00, 14 days overdue) gets one;"),
            Line(.plain, "  INV-1043, paid this morning, does not. The two tests that failed"),
            Line(.plain, "  last turn pass, and three new ones cover partial payments."),
            Line(),
            Line(.dim, "✻ Worked for 5m 30s"),
            Line()
        ] + claudeInput
    }

    /// Codex's screen in the same worktree: its one turn, the migration
    /// the staged turn names (+24).
    static var remindersCodexScreen: [Line] {
        [
            Line(.plain, "› \(remindersCodexLastPrompt)"),
            Line(),
            Line(.accent, "• Added apps/api/migrations/20261020_reminder_schedules.sql (+24)"),
            Line(),
            Line(.plain, "• The migration creates reminder_schedules with the invoice, the"),
            Line(.plain, "  send date, and a unique key on both, so a schedule is written"),
            Line(.plain, "  once per invoice. Run pnpm migrate to apply it."),
            Line(),
            Line(.plain, "› ")
        ]
    }

    /// Claude's empty input box and its hint, drawn with box characters the
    /// terminal font has, so its edges line up.
    private static var claudeInput: [Line] {
        [
            Line(.plain, "╭" + String(repeating: "─", count: 66) + "╮"),
            Line(.plain, "│ >" + String(repeating: " ", count: 64) + "│"),
            Line(.plain, "╰" + String(repeating: "─", count: 66) + "╯"),
            Line(.dim, "  ? for shortcuts")
        ]
    }

    private static var devScreen: [Line] {
        [
            Line(.plain, "$ pnpm dev"),
            Line(),
            Line(.dim, "> duesmith@0.0.0 dev"),
            Line(.dim, "> pnpm --parallel --filter ./apps/* dev"),
            Line(),
            Line(.accent, "apps/api dev:"),
            Line(.plain, "  listening on http://localhost:4000"),
            Line(),
            Line(.accent, "apps/web dev:"),
            Line(.plain, "  VITE ready in 412 ms"),
            Line(),
            Line(.plain, "  ➜  Local:   http://localhost:5173/"),
            Line(.dim, "  ➜  Network: use --host to expose")
        ]
    }

    /// T1 and T2 are committed, two commits ahead of main; T4 and T5 are not.
    private static var gitLog: [Line] {
        [
            Line(.plain, "$ git log --oneline -4"),
            Line(.plain, "4c1d9e2 feat(jobs): find overdue invoices every morning"),
            Line(.plain, "9a07f3b feat(reminders): sketch the reminder schedule model"),
            Line(.plain, "e52b8aa fix(invoices): keep the memo when an invoice is duplicated"),
            Line(.plain, "71d3c40 chore(deps): bump the test runner")
        ]
    }

    // MARK: - The other workspaces

    // Not in the hero, but opened by hand they agree with their rows.

    private static var prReviewScreen: [Line] {
        [
            Line(.plain, "› Summarize what PR #318 changes"),
            Line(),
            Line(.dim, "• It moves credit notes onto invoices and formats money per account."),
            Line(),
            Line(.plain, "› \(prReviewLastPrompt)"),
            Line(),
            Line(.accent, "• Ran gh pr diff 318"),
            Line(.dim, "  └ +214 -37, 6 files"),
            Line(),
            Line(.plain, "• Three problems, most serious first:"),
            Line(),
            Line(.plain, "  1. Major: reopening an invoice applies its credit note twice."),
            Line(.plain, "     applyCredits runs again on reopen and does not check"),
            Line(.plain, "     whether the credit was already applied."),
            Line(.plain, "  2. Minor: formatMoney ignores the account's currency setting."),
            Line(.plain, "  3. Nit: two tests in invoices.test.ts share a name."),
            Line(),
            Line(.dim, "  No files changed."),
            Line(),
            Line(.plain, "› ")
        ]
    }

    private static var taxRoundingScreen: [Line] {
        [
            Line(.plain, "› Round tax per line item, not on the invoice total"),
            Line(),
            Line(.accent, "• Edited apps/api/src/tax/lineTax.ts (+12 -5)"),
            Line()
        ] + codexCommandPrompt("tsc")
    }

    private static var prorationScreen: [Line] {
        [
            Line(.plain, "> Charge the difference when a customer upgrades mid-cycle"),
            Line(),
            Line(.accent, "⏺ Read(apps/api/src/billing/plans.ts)"),
            Line(.dim, "  ⎿  Read 112 lines"),
            Line(),
            Line(.accent, "⏺ Write(apps/api/src/billing/proration.ts)"),
            Line(.dim, "  ⎿  Wrote 72 lines"),
            Line(),
            Line(.accent, "⏺ Bash(pnpm test src/billing)"),
            Line(.dim, "  ⎿  Running…"),
            Line(),
            Line(.accent, "✻ Running tests… (1m 12s · esc to interrupt)")
        ]
    }

    /// The agent stopped on the error and exited, so the pane is back at its
    /// shell's prompt.
    private static var webhookScreen: [Line] {
        [
            Line(.plain, "> \(webhookLastPrompt)"),
            Line(),
            Line(.accent, "⏺ Update(apps/api/src/webhooks/deliver.ts)"),
            Line(.dim, "  ⎿  Updated with 15 additions and 3 removals"),
            Line(),
            Line(.accent, "⏺ Update(apps/api/src/webhooks/deliver.test.ts)"),
            Line(.dim, "  ⎿  Updated with 3 additions"),
            Line(.failure, "  ⎿  API Error: Request timed out."),
            Line()
        ]
    }

    private static var docsScreen: [Line] {
        [
            Line(.plain, "› Document the invoices API and open a pull request"),
            Line(),
            Line(.accent, "• Edited docs/api/invoices.md (+86 -4)"),
            Line(),
            Line(.accent, "• Ran gh pr create --fill"),
            Line(.dim, "  └ #324"),
            Line(),
            Line(.plain, "• Opened #324 with the invoices endpoints documented."),
            Line(),
            Line(.plain, "› ")
        ]
    }

    private static var pageBreaksScreen: [Line] {
        [
            Line(.plain, "› Keep line items from splitting across page breaks"),
            Line(),
            Line(.accent, "• Edited crates/layout/src/paginate.rs (+24 -9)"),
            Line()
        ] + codexCommandPrompt("cargo test -p layout")
    }

    private static var batchRenderScreen: [Line] {
        [
            Line(.plain, "> Render invoices in batches of 50"),
            Line(),
            Line(.accent, "⏺ Update(crates/render/src/batch.rs)"),
            Line(.dim, "  ⎿  Updated with 64 additions and 12 removals"),
            Line(),
            Line(.accent, "⏺ Bash(cargo test -p render)"),
            Line(.success, "  ⎿  ✓ 31 passed"),
            Line(),
            Line(.plain, "⏺ Invoices now render 50 at a time, and #57 is merged."),
            Line(),
            Line(.dim, "✻ Worked for 7m 41s"),
            Line()
        ] + claudeInput
    }

    /// Codex asking at its own prompt before it runs `command`: what the
    /// hook reports as a wait with no request behind it.
    private static func codexCommandPrompt(_ command: String) -> [Line] {
        [
            Line(.plain, "  Would you like to run the following command?"),
            Line(),
            Line(.accent, "  $ \(command)"),
            Line(),
            Line(.accent, "› 1. Yes, proceed"),
            Line(.plain, "  2. Yes, and don't ask again for this command"),
            Line(.plain, "  3. No, and tell Codex what to do differently")
        ]
    }
}
