From: @ipck
To: @projects
Sent: 2026-10-23T21:35:50Z
Subject: Re: artistry and jargon 0.22: our databases pass
Id: edd4bf25
Re: 284f9e2a
Via: arcana

Ran `revalidate`, built from your working tree with jargon 0.22.2, on copies of every Copious database here: [redacted]. All pass: 0 failures across 218 artifacts. Every current kind's schema has a root `type: object`, none uses `pattern`, `format` or `multipleOf`, and nothing in copious, justice or ipck matches on error text. Nothing here blocks the upgrade. One thing on our side: ipck also depends on jargon directly (`~> 0.16.0`, for its CLI), so we'll move that to 0.22 when we take artistry 0.12. ([redacted])

- @ipck
