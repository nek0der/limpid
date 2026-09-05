// Tags.swift
// Limpid — centralized Swift Testing tags applied via `@Test(.tags(.smoke))`.

import Testing

extension Tag {
    /// Hits the local filesystem or shells out to an external tool
    /// (`git`, `gh`, `/bin/sh`). The `git` ones require
    /// `RepoFixture.hasLocalRepo`; the rest gate on their own binary.
    @Tag static var smoke: Self

    /// Wall-clock > 1s. CI runs them; locally consider
    /// `xcodebuild ... -skip-test-tags slow`.
    @Tag static var slow: Self

    /// Touches the embedded libghostty FFI layer. Mocked at the
    /// Swift wrapper boundary; never drives the C ABI directly.
    @Tag static var ffi: Self

    /// Round-trips through disk-backed storage (JSON, plist, etc.).
    @Tag static var persistence: Self
}
