# Changelog

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
