# Coordination

*Updated 2026-10-23*

## @ipck

Artistry's only consumer: Copious and Justice in the ipck monorepo both
depend on it, without a version pin (locked at artistry 0.11.0 and jargon
0.16.0 as of 2026-10-23). Tell @ipck before any release that changes
behavior; the user asked for this one to go to them (2026-10-23).

- **2026-10-23, jargon 0.22.** Artistry sent a heads-up asking ipck to run
  `just revalidate` on its databases before taking 0.12.0. It went out as
  @projects, because artistry had no `.ai/` or handle yet, so the reply
  came to @projects too. The user had the thread moved here (2026-10-23),
  with ipck's private details redacted: `mail/sent/` (`284f9e2a`) and
  `mail/received/` (`edd4bf25`). The reply: every Copious database it checked
  passes, with no failures; every kind's schema has a root `type: object`
  and none uses `pattern`, `format` or `multipleOf`; nothing matches on
  error text. Nothing blocks the upgrade. ipck's own CLI also depends on
  jargon (`~> 0.16.0`) directly, and ipck will move that to 0.22 when it
  takes artistry 0.12.
- **2026-10-23, 0.12.0 and jargon's new source.** Told @ipck (sent as
  @artistry, `mail/sent/`) that 0.12.0 names jargon's new source: stay on
  artistry 0.11.0 until memo releases with the new source too, then take
  both and switch ipck's own jargon line and lock URLs in the same change.
  Asked it to reply to @artistry from now on. **Waiting on memo's release.**
- **2026-10-23, 0.13.0 (indexes).** Told @ipck (`mail/sent/`, before the
  tag) that its `register(index:)` arrays keep their meaning but now cover
  current versions only, that the first open of each store converts the old
  indexes (once; 475 ms at 220k artifacts), that open and close write
  planner statistics, and about `add_index`. Same memo precondition: take
  0.13.0 instead of 0.12.0 once memo releases.

## @jargon

Upstream, and the user's own library. Its Crystal implementation is now
`openbohemians/jargon.cr`, with a Rust port alongside. See status.md for
the move's effect on `shard.yml` sources.

## @memo

Not an artistry consumer, but depends on jargon (`~> 0.16`, which allows
0.22). ipck pulls in both memo and artistry, so the two must name jargon's
source the same way.
