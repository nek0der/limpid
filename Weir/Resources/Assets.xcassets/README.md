Octicons
========

Every `*.imageset` in this catalog holds an SVG taken unmodified from
GitHub's Octicons, at 16px: `x-circle-fill`, `check-circle-fill` and
`dot-fill` for check status.
Weir's own artwork here is the two `*.appiconset` bundles, which are
not Octicons and are covered by the repository's own license.

    SPDX-License-Identifier: MIT
    SPDX-FileCopyrightText: Copyright (c) 2026 GitHub Inc.
    Source: https://github.com/primer/octicons

The full license text is reproduced in `THIRD-PARTY-NOTICES` at the
repository root, which is the notice that ships with the app.

The asset names match the upstream file names on purpose, so a reader
who wonders where a glyph came from can find it without a lookup
table. All three render as template images, so the color comes from
the one view that draws them, `PRHoverCard`. The pull request's mark
on a row is not an Octicon: it is a line drawing of Weir's own
(`SessionPRMark`, `PRLineGlyph`), since a filled shape cannot be
dashed for a draft, so the catalog no longer carries the pull-request
glyphs.

The Octicons repository's README carves GitHub's own logos out of the
grant, directing them to https://github.com/logos instead; the LICENSE
file itself is bare MIT and states no such exception. None of these are
logos either way — they are generic version-control and status glyphs
— so only the MIT terms apply.

`x-circle-fill` and `check-circle-fill` knock their symbol out of the
disc rather than drawing it on top, so whatever sits behind them shows
through it. That only needs handling where something is behind: in the
hover card they sit on the card's own material, which is what should
show, and one drawn on another glyph or over busy artwork needs an
opaque disc under it first.

(`dot-fill` is a solid disc with nothing knocked out.)
