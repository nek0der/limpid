// Tags.swift
// Limpid — centralized Swift Testing tags applied via `@Test(.tags(.smoke))`.

import Testing

extension Tag {
    /// Hits the local filesystem or shells out to an external tool
    /// (`git`, `gh`, `/bin/sh`). The `git` ones require
    /// `RepoFixture.hasLocalRepo`; the rest gate on their own binary.
    @Tag static var smoke: Self

    /// Wall-clock > 1s. Every suite that launches a real tmux server
    /// (`TmuxServerFixture`) carries it, since starting a server, attaching
    /// a control client, and waiting for tmux to answer costs more than a
    /// second on its own, as do the few unit tests that measure an interval.
    /// CI runs them; locally consider
    /// `xcodebuild ... -skip-test-tags slow`, which then leaves the tmux
    /// integration suites out.
    @Tag static var slow: Self

    /// Touches the embedded libghostty FFI layer. Mocked at the
    /// Swift wrapper boundary; never drives the C ABI directly.
    @Tag static var ffi: Self

    /// Round-trips through disk-backed storage (JSON, plist, etc.).
    @Tag static var persistence: Self

    /// Records how tmux itself behaves where a design decision relies on
    /// it, without exercising Limpid's code. A failure after a tmux
    /// upgrade means the premise changed, not that Limpid regressed.
    @Tag static var tmuxBehavior: Self
}
