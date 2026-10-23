## Summary

<!-- One to three sentences: what changed and why. -->

## Related issue

<!-- e.g. Closes #123. Write "Skip." if there is none. -->

## How verified

<!-- Required for user-visible changes. Otherwise write "Build + tests only."
     Examples:
       - "Launched a Debug build, dragged a pane onto a tab, and confirmed it merges."
       - "Ran make screenshot; the Needs Attention list still renders correctly in demo mode." -->

## Screenshots / video

<!-- Required for any UI change. Attach a still, plus a short clip if motion matters. -->

## Checklist

<!-- Tick what applies; leave the rest unchecked (no need to explain why). -->

- [ ] `make lint` passes locally
- [ ] `make test` passes
- [ ] `make review-core` passes (its own CI job; `make test` does not cover it)
- [ ] Tests added or updated where applicable
- [ ] User-facing strings added to `Localizable.xcstrings` with both `en` and `ja`
- [ ] Verified manually on macOS 26 or later — see "How verified" above
- [ ] Code comments are in English
