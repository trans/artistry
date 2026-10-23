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
- **Pending, not yet told:** ipck can't take an artistry or memo release
  that uses jargon's new source until both have one, and then has to
  switch its own jargon line too (see status.md). @ipck hasn't been told:
  it waits on the user's choice of where to tag `v0.12.0`.

## @jargon

Upstream, and the user's own library. Its Crystal implementation is now
`openbohemians/jargon.cr`, with a Rust port alongside. See status.md for
the move's effect on `shard.yml` sources.

## @memo

Not an artistry consumer, but depends on jargon (`~> 0.16`, which allows
0.22). ipck pulls in both memo and artistry, so the two must name jargon's
source the same way.
