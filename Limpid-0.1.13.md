## [0.1.13](https://github.com/nek0der/limpid/compare/v0.1.12...v0.1.13) (2026-10-29)


### Features

* **agent:** show an MCP server's request for input under Claude Code with its words, from its Elicitation hook ([#176](https://github.com/nek0der/limpid/issues/176)) ([8c6cfd2](https://github.com/nek0der/limpid/commit/8c6cfd292056bd42f713552687a98805a3e3bc37))
* **sidebar:** name each row by its branch, and make a name the person gives a label beside it ([#179](https://github.com/nek0der/limpid/issues/179)) ([ded379e](https://github.com/nek0der/limpid/commit/ded379ec514f9e7572a0b2cbaa28c9fe94f5dc74))

## What's Changed
* chore(build): start the CI build without waiting for lint, cache the Rust bridge build and Sparkle, and report the build timing by @nek0der in https://github.com/nek0der/limpid/pull/175
* test(process): give the timing tests room for a busy CI runner, and check the quit's SIGKILL without a clock by @nek0der in https://github.com/nek0der/limpid/pull/177
* feat(agent): show an MCP server's request for input under Claude Code with its words, from its Elicitation hook by @nek0der in https://github.com/nek0der/limpid/pull/176
* feat(sidebar): name each row by its branch, and make a name the person gives a label beside it by @nek0der in https://github.com/nek0der/limpid/pull/179
* chore(build): keep Xcode's compilation cache between CI runs by @nek0der in https://github.com/nek0der/limpid/pull/178
* chore(main): release 0.1.13 by @nek0der in https://github.com/nek0der/limpid/pull/180


**Full Changelog**: https://github.com/nek0der/limpid/compare/v0.1.12...v0.1.13

<!-- limpid-source-commit: e2fe8c8dfb01b6e7e526f802b35f51aacf0ff912 -->
