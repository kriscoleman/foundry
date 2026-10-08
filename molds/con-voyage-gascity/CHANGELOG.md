# Changelog

## [0.16.1](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.16.0...con-voyage-gascity-v0.16.1) (2026-10-08)


### Bug Fixes

* **con-voyage:** add latch-bead guard to every review lens prompt ([c76c1ae](https://github.com/kriscoleman/foundry/commit/c76c1aef5ad8e7bdf79daeee432d9a669e031116))
* **con-voyage:** declare a stacked base branch at sling time (fk-wmhr96) ([c5550d3](https://github.com/kriscoleman/foundry/commit/c5550d397f69c255cd7ca50c90e92c8ce5f467ac))
* **con-voyage:** resolve step bead to real work bead in re-review seed ([4a668d2](https://github.com/kriscoleman/foundry/commit/4a668d27afdd458421632bb882dd12a84f00f5d7))
* default CV_STATE_DIR in cv_resolve_work_bead, add setup-review guard coverage (review fk-hbsmk) ([e0dcb17](https://github.com/kriscoleman/foundry/commit/e0dcb1741606b0bc1e24f114d09d32076b421672))
* narrow setup-review's STEP_META_CHECK to gc.step_ref only (review fk-hbsmk/fk-pbadx/fk-up9s4z BLOCKING-1) ([98286ac](https://github.com/kriscoleman/foundry/commit/98286ac2dfff02c4bce1b41b004e3a44b200d586))
* pin floor-lane-&gt;run_target mapping as guard-coverage regression test (review fk-hbsmk) ([dd186d3](https://github.com/kriscoleman/foundry/commit/dd186d3dec88b77b2cc63f32999b09585ed15755))
* stop resolving ci-repair base target against the wrong bead (review fk-qolcm3) ([0b4c0dc](https://github.com/kriscoleman/foundry/commit/0b4c0dc74ca0e0f747008ae41880c99e1a52ee27))
* thread declared stacked base through all sync call sites (review fk-jvu5md) ([117123f](https://github.com/kriscoleman/foundry/commit/117123ff10ff1e335b6f6609cc2208ffbbba1ca2))
* tighten cv_resolve_work_bead step-bead heuristic to gc.step_ref (review fk-up9s4z) ([2d5eef2](https://github.com/kriscoleman/foundry/commit/2d5eef2db758d2b0175fd98140d282025c09fb5b))

## [0.16.0](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.15.0...con-voyage-gascity-v0.16.0) (2026-10-08)


### Features

* **con-voyage:** base-agnostic CI repair discovery for stacked PRs ([b3fc319](https://github.com/kriscoleman/foundry/commit/b3fc319cdfbd76d39c529f59867e5fb375028c0f))
* **con-voyage:** orphan-sweep order closes beads under a closed workflow root ([cefc867](https://github.com/kriscoleman/foundry/commit/cefc867ea88d1602530afa9d83838169b21760d7))


### Bug Fixes

* bound dedup-lock bd set-state call, widen stale-threshold margin (review fk-k4gebi) ([dc62e02](https://github.com/kriscoleman/foundry/commit/dc62e0241965d0562b3560286a4d1c0afc179131))
* bound flatten_roster_vars under the dedup lock, distinguish store-query failure from confirmed-0 dependent_count (review fk-2v5tdv) ([5f6264b](https://github.com/kriscoleman/foundry/commit/5f6264b6ab810fbaf6baa5bd0ecdfbccc6056f72))
* close rereview-watch leak-fix bd close timeouts, dedup lock, test gaps (review fk-k4gebi) ([dc636bb](https://github.com/kriscoleman/foundry/commit/dc636bb38a9f2122d0afced5446d84613eddd71d))
* **con-voyage-pr-watch:** resolve PART A-native review BLOCKING findings (fk-travno) ([9929670](https://github.com/kriscoleman/foundry/commit/9929670451baee7a83178bcc88e9347e02502035))
* **con-voyage:** add a real reopen command and LOW-only pause (fk-9iqxnx) ([724d526](https://github.com/kriscoleman/foundry/commit/724d526dc2eab861afc7cfa8bf18524d8bf7a30e))
* **con-voyage:** bot-ack regex plurals, snake_case reason, escape-hatch/cross-loop/edge test gaps (fk-wpgt9j send-back) ([60e9523](https://github.com/kriscoleman/foundry/commit/60e952394657c057ba5a9c74e6c83fe2b97e60b8))
* **con-voyage:** bound orphan-sweep candidate enumeration with a timeout ([5ceebcd](https://github.com/kriscoleman/foundry/commit/5ceebcd88945ebb95444339dd7b7529d692752ee))
* **con-voyage:** give rereview-watch's gc sling its own timeout, fix seed-bead leak ([57cbd7e](https://github.com/kriscoleman/foundry/commit/57cbd7e05156441418f9a68368383f48497a6274))
* **con-voyage:** pr-watch must not route AI-reviewer bot acks as feedback (fk-wpgt9j) ([6c371e5](https://github.com/kriscoleman/foundry/commit/6c371e528685363c1eca439edfe0bcfced105dd5))
* **con-voyage:** publish records the reviewed HEAD, not head-at-publish-time ([2468315](https://github.com/kriscoleman/foundry/commit/2468315dfbd1bd3c3106e36d76a25a326753cf6c))
* **con-voyage:** resolve 9 re-graded review findings on mayor-reopen path (fk-9iqxnx) ([c3af260](https://github.com/kriscoleman/foundry/commit/c3af26083dc4b9b32c8819a23b15f6f0251adf93))
* **con-voyage:** resolve aggregated review comment body_file paths as absolute ([0b79a00](https://github.com/kriscoleman/foundry/commit/0b79a0022a3b73b0d0f8e927c527b4fe7bbe8330))
* derive dedup lock stale-threshold from sling hold time, test lock paths (review fk-k4gebi) ([9906a23](https://github.com/kriscoleman/foundry/commit/9906a23eeb7e0b7eeeff2ff2e07c9ed288b54105))
* drop dead $CV_LIB gate on reviewed-sha stamp (review fk-qj2s9r) ([bcec03b](https://github.com/kriscoleman/foundry/commit/bcec03b599590aeab0dd9b7f40d7dd92071ffeb7))
* drop vestigial --json from orphan-sweep digest mail call (repair fk-heub9k) ([61f684a](https://github.com/kriscoleman/foundry/commit/61f684a4aa38848d46a182ae8461dad5134fb687))
* guard empty base_branches array + gate PART A-native discovery behind opt-in (review fk-9expbh) ([0e85b47](https://github.com/kriscoleman/foundry/commit/0e85b471bf980ffc9623aece54c5d8ffb99c85ee))
* pin CV_LOCK_STALE_SECONDS derivation and fallback guard with a test (review fk-2v5tdv) ([0e527f1](https://github.com/kriscoleman/foundry/commit/0e527f15af33c0d50bc622ecae8b226f7ae64af1))
* re-derive $WORKTREE for reviewed-sha stamp instead of ambient cwd (review fk-qj2s9r) ([d728c7f](https://github.com/kriscoleman/foundry/commit/d728c7f04b6d3c9e245b3fdf00cff29e5ac6965a))
* re-derive ROOT_ID/CONVOY_ID in the mayor-reopen pause fence (review fk-tk0dvg) ([3196d51](https://github.com/kriscoleman/foundry/commit/3196d51ba0de707689d023b2ac4a54c9dcf53302))
* resolve reviewed-sha stamp's cross-block ROOT_ID/WORKTREE loss (review fk-p5ko3r) ([0eb403e](https://github.com/kriscoleman/foundry/commit/0eb403e0b040e85e56fe8bb100ab3fe3f58e9439))
* scope orphan-sweep hold check to pinned only, fix ralph rank, cache pinned lookup (review fk-gypn9m) ([ab97f55](https://github.com/kriscoleman/foundry/commit/ab97f55ed1d9a9dcf8cd56870e934f602f0cde2f))
* skip pinned/gate-blocked beads in orphan-sweep, cover failure paths (review fk-gypn9m) ([2ebba13](https://github.com/kriscoleman/foundry/commit/2ebba13dd47db21fcc89b08a3faffc50c6a33230))
* thread review state into is_bot_ack to stop re-dropping CHANGES_REQUESTED/refusal signals (review fk-0wdxhn) ([e226c8f](https://github.com/kriscoleman/foundry/commit/e226c8fda84efa637fde811f8afe74e601a05753))

## [0.15.0](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.14.0...con-voyage-gascity-v0.15.0) (2026-10-04)


### Features

* **con-voyage:** assistant scaffolding — feature flags + suspend/resume handoff notes ([b832b05](https://github.com/kriscoleman/foundry/commit/b832b05e6220aaa728d7c2fcb2fd0e266b28871f))


### Bug Fixes

* avoid merging stderr into a --json gc mail send call (repair fk-u0jac2) ([b201820](https://github.com/kriscoleman/foundry/commit/b201820f0a63a4630f2958816c1499c348971134))
* **con-voyage:** address assistants-scaffolding review findings (fk-apujks) ([f930177](https://github.com/kriscoleman/foundry/commit/f930177a55601b33e3576dc6446c4d7746b31035))
* use bash 3.2-safe idiom for cv_read_handoff_note test (review fk-ho6bs0) ([249a5a4](https://github.com/kriscoleman/foundry/commit/249a5a4082145616814908c2d2b1bc55a3c7f27f))

## [0.14.0](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.13.2...con-voyage-gascity-v0.14.0) (2026-10-04)


### Features

* **con-voyage:** name work branches con-voyage/&lt;bead-id&gt;-&lt;topic-slug&gt; ([68f95eb](https://github.com/kriscoleman/foundry/commit/68f95ebd50bcb2a7b6369d5c570720cf27d4fb39))


### Bug Fixes

* **con-voyage:** address [#162](https://github.com/kriscoleman/foundry/issues/162) branch-naming BLOCKING findings ([977d925](https://github.com/kriscoleman/foundry/commit/977d925a4417a076d31481770944b97b2890009f))
* **con-voyage:** assert fragment BLOCKING examples, ban downgrade wording, cite fk-6os73y ([8cf33be](https://github.com/kriscoleman/foundry/commit/8cf33be7a22a5b6b9ecf2689ec9335d6085881c7))
* **con-voyage:** confirm askuserquestion-watchdog cooldown is session-independent ([d4196b1](https://github.com/kriscoleman/foundry/commit/d4196b1ad5a89c627ff8325a662ff0a0ee10664a))
* **con-voyage:** fail-closed fence nonce + forged-marker coverage ([#163](https://github.com/kriscoleman/foundry/issues/163) follow-up) ([c25fc52](https://github.com/kriscoleman/foundry/commit/c25fc52aa4037ea32d8c6a4e8219655c2ed0c5d8))
* **con-voyage:** pack-wide reviewer severity rubric (LOW = cosmetic only) ([7b5959c](https://github.com/kriscoleman/foundry/commit/7b5959c30d509a48d2655c2ec2ea200a9858f14e))
* **con-voyage:** retry work-branch-name persist and re-derive actual branch on discard ([8ce2b51](https://github.com/kriscoleman/foundry/commit/8ce2b5160ed70331be9838f0b81872673ed7ad68))
* **con-voyage:** unwrap rubric phrases split across markdown soft-wraps ([c2a5a3f](https://github.com/kriscoleman/foundry/commit/c2a5a3f75a0f2ebb5153a3a7517036e4db868e16))

## [0.13.2](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.13.1...con-voyage-gascity-v0.13.2) (2026-10-03)


### Bug Fixes

* **con-voyage:** add shared severity rubric for unenforced preconditions, vacuous acceptance, unstacked deps ([0900eda](https://github.com/kriscoleman/foundry/commit/0900edab26485561d7994f1a0e3be830c95ba7bb))
* **con-voyage:** avoid SIGPIPE/pipefail false refusal in cv-review-lane-worktree.sh acquire ([f425049](https://github.com/kriscoleman/foundry/commit/f425049a05dc0214e7956323e963c2086561779b))
* **con-voyage:** bound unbounded bd show calls in roster-validation helpers ([7da8a29](https://github.com/kriscoleman/foundry/commit/7da8a290efb65df8eea1d2626f90d86952b7eb19))
* **con-voyage:** fail fast on unknown enable_* roster vars; build active roster from formula conditions ([c35775d](https://github.com/kriscoleman/foundry/commit/c35775d292536a511a8056cc81b489d0c16b465c))
* **con-voyage:** fence untrusted PR text in pr-watch feedback beads (fk-7xu9m) ([5533577](https://github.com/kriscoleman/foundry/commit/55335772d2f800e6c1f2f4cab96c71d52b16a4eb))
* **con-voyage:** gate review dispatch on a passed build and an alive workflow root ([862879f](https://github.com/kriscoleman/foundry/commit/862879f4e20a4cc392fda19be2f4cb2a2887f659))
* **con-voyage:** re-review post-publish code pushes with the original roster ([b7e38cf](https://github.com/kriscoleman/foundry/commit/b7e38cf1320f6ac0ed84a69628b017a92f9be093))
* **con-voyage:** require cv-pr-comment.sh + gc.pr_comment_url on routed PR-feedback replies ([176a78c](https://github.com/kriscoleman/foundry/commit/176a78c4ad615ee333a7923cfc481815f7b9ccd8))
* **con-voyage:** resolve re-review formula vars dynamically instead of dead {var} tokens (review fk-sz3vu) ([bb27f58](https://github.com/kriscoleman/foundry/commit/bb27f58ebd5daf82ad769d538aa65b95f4d04862))
* **con-voyage:** stop pr-watch routing bot approvals/slash-commands as human feedback ([e6a6053](https://github.com/kriscoleman/foundry/commit/e6a6053dbf567ff8671839d8b601b4f9a2da7fd5))
* **con-voyage:** tighten pr-watch bot-feedback classifier per human review ([ec17654](https://github.com/kriscoleman/foundry/commit/ec1765498f1c2e4b46dce917518cbb7225af0d6e))
* **con-voyage:** unify pr-watch bot-filter loops + log suppressions ([69bf7e0](https://github.com/kriscoleman/foundry/commit/69bf7e0c8adcce98daf869bba2628d667b8e6f8d))
* push converged re-review fixes to the PR branch and dedupe roster-flattening logic (review fk-n74o9) ([d2ee12d](https://github.com/kriscoleman/foundry/commit/d2ee12de3080d89c78cd2e7131e83a6c4726c9e7))
* resolve $BRANCH in con-voyage rereview-finalize push block (review fk-sz3vu) ([ac2da4d](https://github.com/kriscoleman/foundry/commit/ac2da4df0fe70b4477d8834e9ca871f061118d3b))
* resolve mold-validate failures — dead {{var}} token and --json/2&gt;&1 stderr merge (repair fk-4u5vo) ([ade29ad](https://github.com/kriscoleman/foundry/commit/ade29ad28fe4a31f6e7f5d12fd699cce8887200c))

## [0.13.1](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.13.0...con-voyage-gascity-v0.13.1) (2026-10-02)


### Bug Fixes

* **con-voyage:** tear down the graph.v2 workflow root on PR finalize ([2c6be44](https://github.com/kriscoleman/foundry/commit/2c6be44aa2b2326830eadeaa378b0d3d26370b34))

## [0.13.0](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.12.6...con-voyage-gascity-v0.13.0) (2026-10-02)


### Features

* **con-voyage:** add convention-drift check to frontend review lenses (fk-yhqwj) ([cfacc04](https://github.com/kriscoleman/foundry/commit/cfacc04285cd0f83e176a25edb1e5eb715b02298))


### Bug Fixes

* clarify convention-drift justified-deviation and severity rule (review fk-qdlo9) ([e977d63](https://github.com/kriscoleman/foundry/commit/e977d63a462622d57539be3f8f05b5fa2fb4463f))
* dedupe convention-drift check into a shared template fragment (review fk-qdlo9) ([b40a5b0](https://github.com/kriscoleman/foundry/commit/b40a5b0f30af965ea3138755d4e90c8d943e3615))
* resync convention-drift test needles to shipped fragment wording (review fk-lhjn3) ([56c86f4](https://github.com/kriscoleman/foundry/commit/56c86f40ff682ffa9a5e8deae68758afd7cfe675))

## [0.12.6](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.12.5...con-voyage-gascity-v0.12.6) (2026-10-02)


### Bug Fixes

* **con-voyage:** bump pr-watch order timeout to 8m ([679d42f](https://github.com/kriscoleman/foundry/commit/679d42ffaaeb19a86acc14dfa9820964efd541ca))
* **con-voyage:** self-heal bare repair beads, fix blocked/checks_failed precedence ([34fbb7e](https://github.com/kriscoleman/foundry/commit/34fbb7ec70df9d16d9a618018be547d2a972d425))

## [0.12.5](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.12.4...con-voyage-gascity-v0.12.5) (2026-10-02)


### Bug Fixes

* **con-voyage:** lens agents inherit the gc-role-worker startup claim protocol (fk-famif) ([dff3ff6](https://github.com/kriscoleman/foundry/commit/dff3ff68d598f5852a3c24411ec5f5eea0411115))

## [0.12.4](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.12.3...con-voyage-gascity-v0.12.4) (2026-10-02)


### Bug Fixes

* bound and verify sync-conflict terminal mail/close in main.build.md (review fk-c24ah) ([b6ed626](https://github.com/kriscoleman/foundry/commit/b6ed62620587642678bb63a2c82822d79db4a795))
* **con-voyage:** add cv_session_route_handle unit tests, fix stale publish.md comment (review fk-glv1a) ([b50b542](https://github.com/kriscoleman/foundry/commit/b50b54229c2d33f1610e34c165df46f675468688))
* **con-voyage:** build step fails fast on deterministic sync-to-base conflict (fk-hcxre) ([4d4bd9b](https://github.com/kriscoleman/foundry/commit/4d4bd9b9506b773e6ee216f99bbe6458636cc60a))
* **con-voyage:** pr-watch routes human feedback to the PR's own implementor (fk-krsvc) ([c2f8800](https://github.com/kriscoleman/foundry/commit/c2f8800c4767cba43e7eca1370a8fbc3c8d2cf3b))
* **con-voyage:** prepare-build must not adopt a stale source-anchor branch (fk-2klp2) ([3de7d84](https://github.com/kriscoleman/foundry/commit/3de7d8428f97105494d2a2be826a8c8bfb94b8a3))
* drop stale anchor branch ref and warn on dirty discard (review con-voyage/fk-29ts8) ([5ddbcc5](https://github.com/kriscoleman/foundry/commit/5ddbcc5557e0c2aa4b33d8781d19b37be4690c04))
* prepare-build must create worktree on fresh_build=true (review con-voyage/fk-29ts8) ([ab0044c](https://github.com/kriscoleman/foundry/commit/ab0044c8797f1b4bf39b1953f6ec361750458dec))
* resolve implementor_session from a dedicated key, add pr-watch liveness fallback (review fk-hbsmk) ([e46be80](https://github.com/kriscoleman/foundry/commit/e46be80dd9e2533dc05c86a33e236ec0cde26f1b))
* stamp implementor_session with a gc sling-resolvable rig-scoped handle (review fk-pbadx) ([19c9b50](https://github.com/kriscoleman/foundry/commit/19c9b509838199532a8850c1a8873c636b27bed5))
* too-stale EXISTING_WORK_DIR must rebuild fresh, not reuse in place (review con-voyage/fk-29ts8) ([db5c0fe](https://github.com/kriscoleman/foundry/commit/db5c0feb4e4aaef9399fa21b0f91c5bceb585332))
* write IMPLEMENTOR in bare gc.session_name form, not rig-prefixed (review fk-hbsmk) ([ca47f2d](https://github.com/kriscoleman/foundry/commit/ca47f2da4c6d758a74b18fdf7e82bf2971cc6490))

## [0.12.3](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.12.2...con-voyage-gascity-v0.12.3) (2026-09-30)


### Bug Fixes

* address con-voyage review-loop gate findings (review fk-gfedd) ([ed3ba3d](https://github.com/kriscoleman/foundry/commit/ed3ba3d6bff89df0248f69ff5634254f46e5de7b))
* apply same GC_RIG_ROOT sync bootstrap fix to main.build.md (review fk-n7qn1) ([4ca681c](https://github.com/kriscoleman/foundry/commit/4ca681cd094854b3776c30808f332dda1e508f45))
* **con-voyage:** cv_pack_root falls back on a stale worktree pack copy (fk-fzebe) ([9d4888d](https://github.com/kriscoleman/foundry/commit/9d4888d1f15dff4074812f5bc65d3c5570248833))
* **con-voyage:** declare poll_s once outside cv_with_timeout's loop ([145b7d4](https://github.com/kriscoleman/foundry/commit/145b7d410a9592d88f68a8e600792a5c98441a71))
* **con-voyage:** gate review-loop lane reopen on apply-review-findings landing a fix (fk-itiq6) ([965010a](https://github.com/kriscoleman/foundry/commit/965010a3e5428784b74068866831d10421c87d3c))
* **con-voyage:** prepare-build syncs a freshly-created worktree to origin's current base (fk-grepg) ([8904769](https://github.com/kriscoleman/foundry/commit/89047690cd5254f2daa28dd010a22b4c3b94cf89))
* **con-voyage:** resolve apply-review-findings sync bootstrap via GC_RIG_ROOT (fk-n7qn1) ([efccbef](https://github.com/kriscoleman/foundry/commit/efccbefb1cc50a8f18bd21108ad0520bd40ad09f))
* **con-voyage:** rig-sync no longer treats untracked paths as dirty (fk-vgmb3) ([cea5301](https://github.com/kriscoleman/foundry/commit/cea53016434f5fec7b37d9cd46782ef8b83de753))
* **con-voyage:** sweep orphaned ci-repair beads by title when their PR merges (fk-nrfio) ([309e0d3](https://github.com/kriscoleman/foundry/commit/309e0d3ac3cd498d2618a84d7f0798cf57ef7b7a))

## [0.12.2](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.12.1...con-voyage-gascity-v0.12.2) (2026-09-30)


### Bug Fixes

* **con-voyage:** cv-synthesis-low-mail.sh must not merge stderr into --json parse (fk-pu523) ([13328df](https://github.com/kriscoleman/foundry/commit/13328dfdf4ba46301ed992e7a688f8feedde017b))

## [0.12.1](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.12.0...con-voyage-gascity-v0.12.1) (2026-09-30)


### Bug Fixes

* **con-voyage:** con-voyage-rate-limit-lookout.sh must be 100755 (fk-4gqm0) ([4092ac4](https://github.com/kriscoleman/foundry/commit/4092ac4c3f228d0024cb0a54605b405b2a1c8aaa))

## [0.12.0](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.11.0...con-voyage-gascity-v0.12.0) (2026-09-29)


### Features

* **con-voyage:** add rig-sync order to keep rigs fast-forwarded to origin (fk-hewd2) ([a81853d](https://github.com/kriscoleman/foundry/commit/a81853d3b79a48b6c128ecc1c4913ef6fd0372af))
* **con-voyage:** one aggregated PR review comment per round instead of per-lane spam (fk-9boht) ([d1b788c](https://github.com/kriscoleman/foundry/commit/d1b788c059327fef6f3e66e986a0cac8772dc818))
* **con-voyage:** sync every code-writing step onto current origin/main before it starts (fk-hbsmk) ([7c65e2a](https://github.com/kriscoleman/foundry/commit/7c65e2a0ce6e8933cbe70b7b53a2d4d19323a2d0))


### Bug Fixes

* add stale-lock-steal test coverage to con-voyage-rig-sync (review fk-s850c) ([1771eee](https://github.com/kriscoleman/foundry/commit/1771eeecbf4a4beed666509d715a2e33e0dadb18))
* bound concurrency-test hangs, add full-suite 2x coverage (review fk-78kfl) ([6f02c33](https://github.com/kriscoleman/foundry/commit/6f02c334c76c6657484e5fbac4046562ffe1e3f1))
* clear mint-failure markers unconditionally on every clean observation (review fk-n4c1a) ([ffdd45e](https://github.com/kriscoleman/foundry/commit/ffdd45e0e63beafe058af797b3a7edbb7a7e30fa))
* close_if_open blocked-bead check reads real status field, not dead is_blocked JSON key (review fk-e1u8v) ([6aac5ae](https://github.com/kriscoleman/foundry/commit/6aac5ae026088341a4f17a67ec8a68e1bed6c21f))
* close_if_open FORCE guard is behavior-based, not a status-field guess (review fk-e1u8v) ([0c1cc66](https://github.com/kriscoleman/foundry/commit/0c1cc667997c2748ce536726d4b47ad05a9892a3))
* close_if_open FORCE now confirms via bd blocked/--pinned, not refusal text alone (review fk-e1u8v) ([605caf5](https://github.com/kriscoleman/foundry/commit/605caf5637fa15fee6ba67e994ecc2317ba3a18f))
* close_if_open FORCE refuses to override a pin or unsatisfied gate (review fk-e1u8v) ([6add74f](https://github.com/kriscoleman/foundry/commit/6add74fc1ef766f43cf5b3e1b7410c756c49a169))
* close_if_open pin/gate FORCE guard was dead code, refuses now (review fk-e1u8v) ([da1a2b2](https://github.com/kriscoleman/foundry/commit/da1a2b2041751e607b2f3a68d6a8de2f777cbeda))
* **con-voyage:** bound stalled git fetch in cv_ensure_branch_based_on (fk-0f459) ([755c55d](https://github.com/kriscoleman/foundry/commit/755c55dee21d96d4b8ae332dc20c0dfe5d36e652))
* **con-voyage:** cap fallback-mint retries and roll back orphaned repair beads (fk-zvkmd) ([a36ad15](https://github.com/kriscoleman/foundry/commit/a36ad152d6e03911be1f4578f642af4469d2d5da))
* **con-voyage:** cv-review-* tier providers ship explicit effort (fk-atuxk) ([960f0d5](https://github.com/kriscoleman/foundry/commit/960f0d5a26478802a7984da7dd56fe4584a5a92e))
* **con-voyage:** default GC everywhere in con-voyage-lib.sh so no caller silently no-ops ([1f41e0b](https://github.com/kriscoleman/foundry/commit/1f41e0bafab8692f4f104fa08c5311531f46907f))
* **con-voyage:** finalize monitor forces past the work-bead assignee guard (fk-c1xa) ([12fa780](https://github.com/kriscoleman/foundry/commit/12fa780567d3264ca78db01b6db3af0b93be64e3))
* **con-voyage:** finish pack-script/lib deterministic-resolution migration (review fk-stjtk) ([2a98ae2](https://github.com/kriscoleman/foundry/commit/2a98ae26b589c9baf61d51aab80ee0af33254271))
* **con-voyage:** gate lookout auto-flip on a live opencode spawn probe (gascity[#5436](https://github.com/kriscoleman/foundry/issues/5436)) ([6176cf2](https://github.com/kriscoleman/foundry/commit/6176cf25c13f1197cbd81044dc03aaa0ae678703))
* **con-voyage:** migrate cv_sync_worktree_to_base to cv_pack_script ([56025b4](https://github.com/kriscoleman/foundry/commit/56025b46890f5241bc935650c5aab7dca2e4b7e0))
* **con-voyage:** migrate synthesize-review LOW-mail resolution off find/command-v (fk-sdp0k) ([9d5858d](https://github.com/kriscoleman/foundry/commit/9d5858d5af54b9cdb463a9367d199a026a0e5571))
* **con-voyage:** resolve step prompt files and runtime placeholders (fk-4q6ib) ([61914ec](https://github.com/kriscoleman/foundry/commit/61914ece2e793306790db5d6e4f53f57624ff167))
* **con-voyage:** shape-agnostic finding counter + bounded store calls in cv-synthesis-low-mail.sh (review fk-tkctn) ([33dac23](https://github.com/kriscoleman/foundry/commit/33dac23e3d910ea1850c98a767f7e7eb83864535))
* **con-voyage:** synthesis actually mails the human on a LOW-only verdict ([e616c21](https://github.com/kriscoleman/foundry/commit/e616c2151c0c7939d7185aa6f5e987b4ee0620c3))
* **con-voyage:** use double-brace gc.run_target on ci-repair's v2 step (fk-5foqz) ([0fedc04](https://github.com/kriscoleman/foundry/commit/0fedc04704ab0e329b48515c5aa1e391b8846343))
* eliminate locale-sensitive awk forks from cv_with_timeout's poll loop (review fk-jjumm) ([ca456f7](https://github.com/kriscoleman/foundry/commit/ca456f7b09b13ca2b55ca44d5531a73cf8702619))
* force base-10 arithmetic in cv_with_timeout to avoid octal misparse (review fk-i7d7b) ([e1097b4](https://github.com/kriscoleman/foundry/commit/e1097b4561bf1b0d67759e8db9d6c66f39559757))
* guard $GC default in cv_convoy_target (review fk-4q6ib) ([5219aec](https://github.com/kriscoleman/foundry/commit/5219aecf8f3fe5146f070591706ed82f3fbc57e1))
* guard empty CONVOY_ID before base-branch resolution in publish.md (review fk-4q6ib) ([516b554](https://github.com/kriscoleman/foundry/commit/516b554f8ad659e6550a5ad61d1ebdc71695a7f2))
* LOW_MISMATCH must warn not die on the LOW-only escalation path (review fk-5vupw) ([2c3d288](https://github.com/kriscoleman/foundry/commit/2c3d288b144f2c47a235f1d3112abe8b2ad4cc81))
* match bold **None.** zero-case body in synthesis LOW-mail parser (review fk-5vupw) ([4982a80](https://github.com/kriscoleman/foundry/commit/4982a8089f05681950bcf97a56d155555a4a70bf))
* point con-voyage-sync-base.test.sh CASE 7 at renamed main.*.md workflow files ([8e0a496](https://github.com/kriscoleman/foundry/commit/8e0a4964fae5e7b1a9d280ab63bebb33b1fc12f5))
* rename regression + $GC unset in cv_bead_metadata (review fk-4q6ib) ([6bc0e11](https://github.com/kriscoleman/foundry/commit/6bc0e117c8555f6077c9dee7aa41f8ff3ea9993a))
* reorder BLOCKING no-op exit before LOW-count validation in synthesis mail parser (review fk-5vupw) ([eac4b43](https://github.com/kriscoleman/foundry/commit/eac4b4389d3c5552e78ac4ed07b956c0bc683fd8))
* rollback bd close drops --city and reset mint markers on PR recovery (review fk-pl4mt) ([6cfa59e](https://github.com/kriscoleman/foundry/commit/6cfa59e699ec277e25ae022941f3a88b2c1a83d4))
* sync the real worktree and resolve cv-worktree-prep.sh deterministically (review fk-661ld) ([750a930](https://github.com/kriscoleman/foundry/commit/750a9306d73ec5de312af288c1bde9a9c15c5701))
* taper cv_with_timeout's poll interval to avoid a ~1s tax on the fast path (review fk-jjumm) ([5b5340d](https://github.com/kriscoleman/foundry/commit/5b5340d1893a0e322ca2c72674308b7e47bdb8ca))

## [0.11.0](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.10.1...con-voyage-gascity-v0.11.0) (2026-09-28)


### Features

* **con-voyage:** city-wide AskUserQuestion stall watchdog (fk-o9ntx) ([8a75988](https://github.com/kriscoleman/foundry/commit/8a75988631c17583b41d0b7e7b103330cc1188bc))


### Bug Fixes

* harden con-voyage-askuserquestion-watchdog against silent gc call failures (review fk-6vf0c) ([49d1921](https://github.com/kriscoleman/foundry/commit/49d1921d339ba8c9632867e2f1a891c90afffeef))

## [0.10.1](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.10.0...con-voyage-gascity-v0.10.1) (2026-09-28)


### Bug Fixes

* **con-voyage:** catch two more nondeterministic resolution sites (fk-q2pon) ([607d3ef](https://github.com/kriscoleman/foundry/commit/607d3efc5b7312540f8007ed11148cdfbbd42fb8))
* **con-voyage:** cv_pack_script exits 0 on a miss, not 1 (fk-q2pon LOW-A) ([d26560c](https://github.com/kriscoleman/foundry/commit/d26560c1a4c6128f30d0d94412ea9ca78262905b))
* **con-voyage:** ensure-scripts refresh a stale seeded gate/validator copy (fk-6z17l) ([3513cc0](https://github.com/kriscoleman/foundry/commit/3513cc06fa6cd53c67d351c89f2b82d1f6fd4774))
* **con-voyage:** fail fast when prepare-build did not pass (fk-03g4s) ([b540ee4](https://github.com/kriscoleman/foundry/commit/b540ee441e347638ea463db355d54381140e916f))
* **con-voyage:** harden ensure-scripts' stale-replace against symlinked destinations (fk-6z17l review follow-up) ([1e97591](https://github.com/kriscoleman/foundry/commit/1e97591143905de16e909a145dd65fae463d48eb))
* **con-voyage:** resolve pack scripts and lib deterministically (fk-q2pon) ([2969af1](https://github.com/kriscoleman/foundry/commit/2969af1a4ba3b7a7267f365788485644f5f4aede))
* **con-voyage:** review-watchdog holds off on not-ready lanes and suspects provider freezes (fk-7ba34) ([eac7a03](https://github.com/kriscoleman/foundry/commit/eac7a0326ca23a1de4e3c28fdd37c0439f7126d9))
* **con-voyage:** tighten pack-script-resolution regression coverage (fk-q2pon LOW-B/C/D) ([02edcaf](https://github.com/kriscoleman/foundry/commit/02edcafd9287bb122c2c5b014a6a01a1e970c0e0))
* default $GC before cv_dependency_outcome so the fail-fast skip actually fires (review fk-2yhob) ([97c9cae](https://github.com/kriscoleman/foundry/commit/97c9caef57db07b0cd0b6f47e0709240dc70a4ca))

## [0.10.0](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.9.2...con-voyage-gascity-v0.10.0) (2026-09-28)


### Features

* **con-voyage:** three-tier model architecture + con-voyage-lookout monitor ([5c7afa5](https://github.com/kriscoleman/foundry/commit/5c7afa55e79b39abf1e672ab949959dbe34ec494))


### Bug Fixes

* **con-voyage:** add drift check for the city.toml model-mode override ([a6d81f3](https://github.com/kriscoleman/foundry/commit/a6d81f3591e9e302afd5899ae0920381a2e0d88f))
* **con-voyage:** declare tier model choices via flag_args for gc 1.4.2 ([a89244d](https://github.com/kriscoleman/foundry/commit/a89244d72e7e588aeb073c453c0613ef94b83c48))
* **con-voyage:** default model tiers to claude, make lookout opt-in ([21ffd2f](https://github.com/kriscoleman/foundry/commit/21ffd2fdf9130e174e4011d3b69160d4efb18e58))
* **con-voyage:** lookout escalates before handoffs, fits the order deadline, and leaves auto-resuming sessions alone ([3e34004](https://github.com/kriscoleman/foundry/commit/3e340045982d187e62daf618733286b3e3442911))
* **con-voyage:** rename con-voyage-lookout to con-voyage-rate-limit-lookout ([41c7322](https://github.com/kriscoleman/foundry/commit/41c7322937b2649f390dd168d352f5a143f27651))

## [0.9.2](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.9.1...con-voyage-gascity-v0.9.2) (2026-09-26)


### Bug Fixes

* **con-voyage:** lift pr-watch/repair-watchdog lock into con-voyage-lib.sh ([24df891](https://github.com/kriscoleman/foundry/commit/24df891107ae4d165aaec905530b8b9a4ea9d39c))
* **con-voyage:** repair-watchdog threads repair_bead and skips re-dispatch for already-green PRs ([caad0cf](https://github.com/kriscoleman/foundry/commit/caad0cff2ffef5250bd37400cca566d6a595cb6e))

## [0.9.1](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.9.0...con-voyage-gascity-v0.9.1) (2026-09-26)


### Bug Fixes

* **con-voyage:** harden review-watchdog TSV parsing, warnings, and multi-store timeouts (fk-rri7q) ([27f7065](https://github.com/kriscoleman/foundry/commit/27f70657ccd5140c4eb0befd665c934a4e9b1262))
* **con-voyage:** re-review the fix, not just trust done, after a BLOCKING finding (fk-w31l7) ([f0e2b3c](https://github.com/kriscoleman/foundry/commit/f0e2b3c70f09bcce0aa74a394b4dbc919003d458))
* **con-voyage:** scope setup-review test's CV_LIB count to RIG_ROOT blocks (fk-4jdeh) ([e73be13](https://github.com/kriscoleman/foundry/commit/e73be13bc2621b4758ee371db3e628abb3f80695))
* **con-voyage:** seed gate/validator scripts to the rig root, not the city root (fk-4jdeh) ([8024ea2](https://github.com/kriscoleman/foundry/commit/8024ea2df1acca363ec32cd7638be1a91c464837))

## [0.9.0](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.8.0...con-voyage-gascity-v0.9.0) (2026-09-26)


### Features

* **con-voyage:** thread a per-journey base branch for GitHub stacked PRs (fk-qppb4) ([511c54b](https://github.com/kriscoleman/foundry/commit/511c54bbd9896529f59bb8dc3efe0f092bf22a7d))


### Bug Fixes

* **con-voyage:** address LOW findings from the fk-2c937 review ([7b41a3a](https://github.com/kriscoleman/foundry/commit/7b41a3a71462f8d42d5b41116734ff1f2c487ea8))
* **con-voyage:** attach a named branch after the build commit and as a publish backstop ([e042fd8](https://github.com/kriscoleman/foundry/commit/e042fd81328fb64e169fcda504f623146296fd8c))
* **con-voyage:** build phase reuses a work bead's prior built anchor, not just the sling's fresh convoy (fk-ki8je) ([23ad406](https://github.com/kriscoleman/foundry/commit/23ad406e1873ee0b95c08da385b505b5cc4a4c86))
* **con-voyage:** consume rig-level finalize records from the city-scoped order ([abee2f5](https://github.com/kriscoleman/foundry/commit/abee2f58e2831e4a1840c9174e6e0527dee25ba4))
* **con-voyage:** fix stacked-PR base resolution BLOCKING findings (review fk-hrbj7) ([1077267](https://github.com/kriscoleman/foundry/commit/1077267c1ceff9785a922f5a82c3b46536c00159))
* **con-voyage:** fix stall-detector footer order and tautological fixture (review fk-higuf) ([dd3cacd](https://github.com/kriscoleman/foundry/commit/dd3cacd8a474a96a6a18361b63f022bd15d36b3f))
* **con-voyage:** make repair-watchdog's stale-lock steal atomic (review fk-uxj98) ([2f4c5e7](https://github.com/kriscoleman/foundry/commit/2f4c5e7ee29a2e87c1a921f317e11e457d224a4d))
* **con-voyage:** make the B2 zsh regression test non-tautological (review fk-hrbj7) ([edf15eb](https://github.com/kriscoleman/foundry/commit/edf15ebfb11276533b99f49a898a35dfad02dd63))
* **con-voyage:** make the review watchdog scan every registered rig's store ([9706f61](https://github.com/kriscoleman/foundry/commit/9706f6191a189fc2fa1220783a77d75ea4c0d21a))
* **con-voyage:** pin fixture git identity in stacked-pr-base test (repair fk-2y6e3) ([c229b8a](https://github.com/kriscoleman/foundry/commit/c229b8ae8cc670e516325e21833f8f3689c6c13e))
* **con-voyage:** prevent duplicate re-dispatch lineages in repair-watchdog ([cca6f98](https://github.com/kriscoleman/foundry/commit/cca6f9875808d48b23cc182ada69d5ab825186df))
* **con-voyage:** render convoy_id and other vars cleanly in workflow prompts ([71c3def](https://github.com/kriscoleman/foundry/commit/71c3def958a282460fe4699c0988b668a6864461))
* **con-voyage:** resolve validate_build_artifact.py schemas from either deployment depth ([dee74e3](https://github.com/kriscoleman/foundry/commit/dee74e3ccbe52201e5691d08cb9bf45dc461a3e7))
* **con-voyage:** route Netlify deploy-preview comments as bot, not human feedback (fk-5zc65) ([86ac57e](https://github.com/kriscoleman/foundry/commit/86ac57e831428bcae0f9a7ee97785f7e1cab6c72))
* **con-voyage:** stop the review loop re-iterating after a no-op approval (fk-s15g6) ([1f1e6a1](https://github.com/kriscoleman/foundry/commit/1f1e6a1fe35310b0346cd1aa42eac6c6316d84ae))
* **con-voyage:** warn headless workers off interactive prompts, add stall detector ([d486ac6](https://github.com/kriscoleman/foundry/commit/d486ac6709efa9b681ab3a662b368c9472d49e8f))
* correct stray double-brace convoy_id tokens in con-voyage templates (repair fk-rgqgs) ([7d06b56](https://github.com/kriscoleman/foundry/commit/7d06b56c4b593287bc90cc815ef24ad82cddf7f6))

## [0.8.0](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.7.11...con-voyage-gascity-v0.8.0) (2026-09-25)


### Features

* **con-voyage:** add branch-completeness and blocking-work checks to code-lens hardening (fk-47a6q) ([f8509b2](https://github.com/kriscoleman/foundry/commit/f8509b2033241b013b15005816a11e6b13bd3c69))
* **con-voyage:** fold the do-work build into con-voyage as its own first phase (fk-9aunv) ([e8324ca](https://github.com/kriscoleman/foundry/commit/e8324ca9577ac9815b078f0bb7f541f167ef5a6c))
* **con-voyage:** harden review lens prompts to catch [#10494](https://github.com/kriscoleman/foundry/issues/10494)-class regressions (fk-7fego) ([be3f9e1](https://github.com/kriscoleman/foundry/commit/be3f9e12ba31f5335a23585d1c69c6f98a58986b))


### Bug Fixes

* set $GC before sourcing con-voyage-lib.sh; unnest build-summary schema from Fresh-bead section (review fk-sbr3z) ([204eede](https://github.com/kriscoleman/foundry/commit/204eedebc530cb7b77d13bf9ad9e5b4bbfaa2637))

## [0.7.11](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.7.10...con-voyage-gascity-v0.7.11) (2026-09-24)


### Bug Fixes

* **con-voyage:** scope cv-verify-review-approved.sh's bd list to the owning rig, not the city root (fk-t2fsa) ([f8b97b7](https://github.com/kriscoleman/foundry/commit/f8b97b7bff56c97de268134d3b517a1e437d94b4))

## [0.7.10](https://github.com/kriscoleman/foundry/compare/con-voyage-gascity-v0.7.9...con-voyage-gascity-v0.7.10) (2026-09-24)


### Bug Fixes

* **con-voyage:** claim the WORK BEAD under a non-routable identity (fk-9f2n) ([381695a](https://github.com/kriscoleman/foundry/commit/381695ac54f5b0e8090a976750efec280e0e83cb))

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
