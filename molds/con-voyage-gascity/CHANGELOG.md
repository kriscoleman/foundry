# Changelog

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
