# Changelog

## [0.7.9](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.7.8...con-voyage-gascity-v0.7.9) (2026-09-23)


### Bug Fixes

* address con-voyage review BLOCKING findings B1-B4 (review fk-abxo) ([f59b788](https://github.com/kriscoleman/foundry/commit/f59b788d44ebdca73478592668b8b494fdda9813))
* **con-voyage:** rename zsh-reserved local status to bead_state ([6d721e2](https://github.com/kriscoleman/foundry/commit/6d721e2836ce38a0011d2f5f8f9048d03b3df4dd))
* **con-voyage:** resolve CV_STATE_DIR from the rig root, not the city root (fk-mr07) ([36a4f58](https://github.com/kriscoleman/foundry/commit/36a4f58fd7a2d7d4aa2fca0b47fbbc3f0cac3b0f))
* **con-voyage:** ship + self-seed the build-artifact validator dependency ([2da20f4](https://github.com/kriscoleman/foundry/commit/2da20f4d259208e46cf2239d9f228325f88138d7))

## [0.7.8](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.7.7...con-voyage-gascity-v0.7.8) (2026-09-23)


### Bug Fixes

* **con-voyage:** ship + self-seed gate check scripts, verify before publish ([9bd6458](https://github.com/kriscoleman/foundry/commit/9bd64581d93d77b5ba1f5402c581e76bea079c2b))

## [0.7.7](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.7.6...con-voyage-gascity-v0.7.7) (2026-09-22)


### Bug Fixes

* **con-voyage:** commit review fixes before publish pushes HEAD ([c73f0b3](https://github.com/kriscoleman/foundry/commit/c73f0b30801bc8d9b115ec81e34144d56b53ab1a))
* **con-voyage:** stop asserting the operator's shell is always zsh (fk-0o4d) ([1987ec0](https://github.com/kriscoleman/foundry/commit/1987ec015736496b29888a4da2aba0b2fcf9cf28))
* **con-voyage:** use zsh-compatible read -A in shell-safety reminder (fk-k14n) ([7d94873](https://github.com/kriscoleman/foundry/commit/7d948730d4020403d0d55f595332a6986d5df815))
* **con-voyage:** warn agents about the zsh word-splitting footgun (fk-k14n) ([4b08ac9](https://github.com/kriscoleman/foundry/commit/4b08ac93f9321d7df818c54a6461f5e6115486cb))

## [0.7.6](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.7.5...con-voyage-gascity-v0.7.6) (2026-09-22)


### Bug Fixes

* **con-voyage:** drop --city from lib/finalize bd+mail calls (fk-7v3r) ([1230557](https://github.com/kriscoleman/foundry/commit/1230557ee6f08d77c5a2cd3c48cc7be0421d9fcf))
* **con-voyage:** isolate review lanes into per-lane worktrees (fk-q659) ([3ead89c](https://github.com/kriscoleman/foundry/commit/3ead89c6d85388f2483fab670c0fbff3a0377268))

## [0.7.5](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.7.4...con-voyage-gascity-v0.7.5) (2026-09-21)


### Bug Fixes

* **con-voyage:** pr-watch dedup keys on PR-number; update repair bead on failure_kind flip instead of re-minting (fk-zyh5) ([461c2dd](https://github.com/kriscoleman/foundry/commit/461c2dd29034cd2970d0e29f042af87a1ab86883))

## [0.7.4](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.7.3...con-voyage-gascity-v0.7.4) (2026-09-20)


### Bug Fixes

* **con-voyage:** integer-coerce review-loop lens knobs (fk-jpxo) ([9f76ce4](https://github.com/kriscoleman/foundry/commit/9f76ce4685a60c4199b34644dbac309f7ccbff3a))
* **con-voyage:** silence shellcheck SC2016 on literal $VAR grep patterns ([2033b7e](https://github.com/kriscoleman/foundry/commit/2033b7e1bcf6a65b6c6c85a6ecb1e55bf729761c))

## [0.7.3](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.7.2...con-voyage-gascity-v0.7.3) (2026-09-20)


### Bug Fixes

* **con-voyage:** escalate immediately when a review lane has no gc.routed_to (fk-loo1) ([bf0524e](https://github.com/kriscoleman/foundry/commit/bf0524ef02fecb872ef901cf4a839769cf7abaa0))
* **con-voyage:** review-lane liveness guard — re-dispatch stalled lenses (fk-loo1) ([43bf421](https://github.com/kriscoleman/foundry/commit/43bf421e9562d9d898dde3967cff0654bbd75a4d))

## [0.7.2](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.7.1...con-voyage-gascity-v0.7.2) (2026-09-20)


### Bug Fixes

* **con-voyage:** finalize monitor closes repair beads on PR merge/close (fk-f1vp) ([638c2f4](https://github.com/kriscoleman/foundry/commit/638c2f44a111b71f0aa1dc4ba3e46292b302bfa6))

## [0.7.1](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.7.0...con-voyage-gascity-v0.7.1) (2026-09-20)


### Bug Fixes

* **con-voyage:** ci-repair closes the repair bead, not just the input convoy (fk-7mw7) ([e083cb6](https://github.com/kriscoleman/foundry/commit/e083cb602c856c1fe8f67eeee30826e9dd2039df))

## [0.7.0](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.6.0...con-voyage-gascity-v0.7.0) (2026-09-19)


### Features

* **con-voyage:** drive the work-bead lifecycle end-to-end (fk-p7j9, subsumes fk-hsca) ([6c7a25e](https://github.com/kriscoleman/foundry/commit/6c7a25e4f4ff6da21fd291f5668f4d1899043455))

## [0.6.0](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.5.1...con-voyage-gascity-v0.6.0) (2026-09-19)


### Features

* **con-voyage:** repair-worker watchdog — self-heal dead/stalled rework (fk-wgqp) ([d3816b5](https://github.com/kriscoleman/foundry/commit/d3816b58cde1532b10a1d7e09886280d6a368355))


### Bug Fixes

* **con-voyage:** address Fix-2 round-1 review findings (fk-lfan) ([4a87f24](https://github.com/kriscoleman/foundry/commit/4a87f243c4e702628446cde3d123602aecd87a65))
* **con-voyage:** address Fix-2 round-2 niceties (fk-cied) ([96809c7](https://github.com/kriscoleman/foundry/commit/96809c7f6bc4b09b4528acdcef08459e6e5dffd7))

## [0.5.1](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.5.0...con-voyage-gascity-v0.5.1) (2026-09-18)


### Bug Fixes

* **con-voyage:** address Fix-1 round-1 review findings (rig guard, dedup) ([a4c14bc](https://github.com/kriscoleman/foundry/commit/a4c14bc6fb652737dec52f58a5a71c40fd19fb88))
* **con-voyage:** address Fix-1 round-2 review findings (docs, CASE 37b) ([915ea2e](https://github.com/kriscoleman/foundry/commit/915ea2eaeedafc7009274cfc8ca9d2ad666b710b))
* **con-voyage:** route PR repairs to the long-lived implementor (dedup + re-detection) ([36b20de](https://github.com/kriscoleman/foundry/commit/36b20de583def193bcd0d58066c9b7ee3254b592))

## [0.5.0](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.4.1...con-voyage-gascity-v0.5.0) (2026-09-18)


### Features

* **con-voyage:** reply within the review thread when addressing an inline PR comment (C10) ([281e1de](https://github.com/kriscoleman/foundry/commit/281e1de25ee4812eee2bfb915d78b771894d53b1))

## [0.4.1](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.4.0...con-voyage-gascity-v0.4.1) (2026-09-17)


### Bug Fixes

* **con-voyage-pr-watch:** drop impersonation disclaimer from identity banner ([3d477f3](https://github.com/kriscoleman/foundry/commit/3d477f364785307abfa20913182d799e8f3768a1))
* **con-voyage-pr-watch:** PART B — poll every monitor + route to the repo's rig worker (C8+C9) ([f529903](https://github.com/kriscoleman/foundry/commit/f52990373d79347eb49338b9a648ae7922bf9af3))
* **con-voyage-pr-watch:** route inline reviewThreads via GraphQL — PART B (C7) ([7667e84](https://github.com/kriscoleman/foundry/commit/7667e84ab0e9689e8f0a7f4009df61692914ed36))
* **con-voyage-pr-watch:** stop routing the bot's own bannered comments as human feedback ([18c9884](https://github.com/kriscoleman/foundry/commit/18c9884cbc05d314038b618be6847da1802deda1))
* **con-voyage:** drop PR-comment banner scan, keep cv-pr-comment.sh as sole enforcement ([0296c76](https://github.com/kriscoleman/foundry/commit/0296c76e14204e88e381d7fcd0ecf4dfa1b1d69a))
* **con-voyage:** enforce machine-identity banner + external-rig artifact hygiene (C4+C1) ([f6156fc](https://github.com/kriscoleman/foundry/commit/f6156fc0899288fa754c368aa644672e2e55f848))
* **con-voyage:** monitor mint correctness — dedup on PR-number + skip REVIEW_REQUIRED-only (C5+C6) ([849f676](https://github.com/kriscoleman/foundry/commit/849f6768e825cdaed58b66cd1edd0f7430fc80ea))

## [0.4.0](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.3.2...con-voyage-gascity-v0.4.0) (2026-09-16)


### Features

* **con-voyage-pr-watch:** native-monitor parity — per-state failure_kind classification + repair semantics ([d6a4434](https://github.com/kriscoleman/foundry/commit/d6a4434ee4c817eb0e434f03c2f1cd9f51b46dec))


### Bug Fixes

* **con-voyage-pr-watch:** resolve 3-lens review findings on fk-08o (field-shift regression + cv_conflict_strategy) ([ce0b1c0](https://github.com/kriscoleman/foundry/commit/ce0b1c05c1d994d70086d5113bfa6387e08fa9cf))
* **con-voyage-pr-watch:** surface real gh error text on PART B comment-fetch failure ([ee11417](https://github.com/kriscoleman/foundry/commit/ee114174e93142f88e535e0bea4ce5e05da2bc55))

## [0.3.2](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.3.1...con-voyage-gascity-v0.3.2) (2026-09-15)


### Bug Fixes

* **con-voyage-pr-watch:** create repair bead in the target rig for cross-rig routing ([13959e1](https://github.com/kriscoleman/foundry/commit/13959e124bacb4380012cf29207bbb77a8b122e6))

## [0.3.1](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.3.0...con-voyage-gascity-v0.3.1) (2026-09-15)


### Bug Fixes

* **con-voyage-pr-watch:** mint repair bead via correct v2-formula sling ([d852f4b](https://github.com/kriscoleman/foundry/commit/d852f4b6810ad3f48fca161127abeba001ffbad3))

## [0.3.0](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.2.2...con-voyage-gascity-v0.3.0) (2026-09-15)


### Features

* **con-voyage-ci-repair:** configurable author gate (default fail-closed) ([f85760c](https://github.com/kriscoleman/foundry/commit/f85760c7aa49eab01d84fb7d64b49042efce2956))


### Bug Fixes

* **con-voyage:** clean up ci-repair author-gate LOW review findings ([f245935](https://github.com/kriscoleman/foundry/commit/f24593507c8a2f3d481363e5f950bb274ab9d506))
* **con-voyage:** fail-closed author gate + bead guard for ci-repair ([c93db5f](https://github.com/kriscoleman/foundry/commit/c93db5fbaa06760b4e2d50421a2ffefd0c0f16b0))
* **con-voyage:** finalize ci-repair author-gate blocking fixes ([3f82faf](https://github.com/kriscoleman/foundry/commit/3f82fafcb313667e950ff5e1bf53feb803a18539))

## [0.2.2](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.2.1...con-voyage-gascity-v0.2.2) (2026-09-11)


### Bug Fixes

* **con-voyage:** defensively re-verify PR author in PART B before routing ([bb61eb0](https://github.com/kriscoleman/foundry/commit/bb61eb0b776897cfecbc832658511b82d7761205))
* **con-voyage:** make PART B awk repo parser BSD/macOS-portable ([e66b913](https://github.com/kriscoleman/foundry/commit/e66b91340c5ee1c91f1c0a785414dc66145baeff))
* **con-voyage:** require machine-identity banner on ci-repair PR comments ([ef6eb51](https://github.com/kriscoleman/foundry/commit/ef6eb51ade10bdf70181ba3dc3e65c67d6b788e2))
* **con-voyage:** retrigger CI non-destructively via gh run rerun ([5146a3b](https://github.com/kriscoleman/foundry/commit/5146a3bad7ed8bb7832d53b7a8cec8d22928587f))

## [0.2.1](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.2.0...con-voyage-gascity-v0.2.1) (2026-09-11)


### Bug Fixes

* **con-voyage:** author-scope PR monitor so it only acts on the operator's PRs ([eb511f1](https://github.com/kriscoleman/foundry/commit/eb511f1a9ca4d6414a7ab48937a54059927f856d))
* **con-voyage:** stop ailloy flattening gc-runtime tokens to &lt;no value&gt; ([81de20c](https://github.com/kriscoleman/foundry/commit/81de20cba13192ddf2fdbfa8b95b16a01189a5d7))

## [0.2.0](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.1.0...con-voyage-gascity-v0.2.0) (2026-09-10)


### Features

* **con-voyage-gascity:** add native GitHub PR monitoring with CI repair and human-comment routing ([c108354](https://github.com/kriscoleman/foundry/commit/c10835479f868c86f5962298edf7034ddeaa343c))


### Bug Fixes

* **con-voyage-gascity:** pass PR JSON to python via stdin (heredoc was overriding the pipe) ([6bfb2a4](https://github.com/kriscoleman/foundry/commit/6bfb2a46fee47877e5effa64ff8f51b9ae21e0dd))

## 0.1.0

- initial scaffold — mold metadata, flux mapping, pack skeleton
