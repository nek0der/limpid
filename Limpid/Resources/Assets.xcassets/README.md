Octicons
========

Every `*.imageset` in this catalog holds an SVG taken unmodified from
GitHub's Octicons, at 16px: the four pull-request state glyphs, plus
`x-circle-fill`, `check-circle-fill` and `dot-fill` for check status.
Limpid's own artwork here is the two `*.appiconset` bundles, which are
not Octicons and are covered by the repository's own license.

    SPDX-License-Identifier: MIT
    SPDX-FileCopyrightText: Copyright (c) 2026 GitHub Inc.
    Source: https://github.com/primer/octicons

The full license text is reproduced in `THIRD-PARTY-NOTICES` at the
repository root, which is the notice that ships with the app.

The asset names match the upstream file names on purpose, so a reader
who wonders where a glyph came from can find it without a lookup
table. All seven render as template images, so the colour comes from
whichever view draws them: `PRMarkPresentation` for the four
pull-request glyphs and the failing-check badge, `PRHoverCard` for the
three check-status ones.

The Octicons repository's README carves GitHub's own logos out of the
grant, directing them to https://github.com/logos instead; the LICENSE
file itself is bare MIT and states no such exception. None of these are
logos either way — they are generic version-control and status glyphs
— so only the MIT terms apply.

`x-circle-fill` and `check-circle-fill` knock their symbol out of the
disc rather than drawing it on top, so whatever sits behind them shows
through it. That only needs handling where something is behind: the
sidebar badge rides on another glyph, so `ContainerRow` gives it an
opaque `LimpidColor.statusGlyphKnockout` disc first. In the hover card
they sit on the card's own material, which is what should show. Use
one of these over busy artwork and the same care applies.

(`dot-fill` is a solid disc with nothing knocked out.)
