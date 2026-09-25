---
name: gc-slack
description: Send or read a Slack message from any agent in the city, not just the mayor — reply to an inbound message, post proactively to a channel, react, or delegate to a peer — via the `gc slack` CLI. Use whenever a task calls for Slack output or input, e.g. "reply on slack", "post an update to the channel", "react to that message", "delegate this to <agent> over slack".
---

# GC Slack

Any agent in the city can talk over Slack through the imported Slack pack's
`gc slack` CLI, not just the mayor. The mayor is the default point of contact
for anything ambiguous or cross-cutting, but a worker, reviewer, or watchdog
that owns a conversation should use these commands directly rather than
routing every reply through the mayor.

The verb surface below depends on which Slack pack tier a city imported
(`slack-mini` / `slack-channel` / `slack-full`) — not every verb exists in
every city. Run `gc slack --help` first; if that falls through to the root
`gc` help instead of a `slack` command list, no Slack pack is imported here.
`gc slack <verb> --help` is the living reference for exact flags — this skill
covers the behavior that isn't obvious from `--help` alone.

## Session id, not alias

Outbound commands attribute the post to a session and bind by **session id**
(`$GC_SESSION_ID`, e.g. `rc-kbvpi`), not a human-friendly alias. Passing an
alias where a session id is expected (e.g. `--session mayor`) fails with
"does not own binding ... bound to `<other-session-id>`" even when the alias
resolves fine elsewhere. Use `$GC_SESSION_ID` literally.

## Replying to an inbound message

```bash
gc slack reply-current --conversation-id <channel-id> --body-file <path>
```

**Always pass `--conversation-id` explicitly.** Without it, `reply-current`
scans this session's own recent transcript for its "latest inbound event" —
on a session bound to more than one conversation (e.g. a channel and a DM),
that scan can resolve the wrong one and answer a channel question into a DM.

**Threading:** an inbound that was itself a thread reply is answered in the
same thread by default. To force a specific thread, pass `--reply-to <ts>`.
Do not reach for `--thread-current` as a substitute — it **ignores**
`--conversation-id` for its thread anchor and always threads under the
session's latest inbound *from any bound conversation*, which can silently
anchor your reply to the wrong thread (Slack posts top-level, and the
readback reports `Delivered:false`). Trust the printed JSON's `status` /
`posted_ts`, not just a zero exit code.

If your reminder was delivered in company-room mode (see "Two conversation
models" below) it hands you an exact `--turn-ref <turn_ref>` — copy that
command instead of reconstructing `--conversation-id` / `--reply-to` by hand.

## Reacting to a message

```bash
gc slack react --conversation-id <channel-id> --message-id <ts> --emoji eyes
```

Same risk as `reply-current`: omitting `--conversation-id` / `--message-id`
falls back to "latest inbound for this session," which is wrong on a
multi-binding session. Pass both explicitly whenever you know them.

## Posting proactively (not answering an inbound)

`gc slack publish` posts to a session's *saved binding* — but on a session
with more than one binding it picks "the last one in API (ID) order," which
is not a reliable default. When you know the exact channel, use
`publish-to-channel` instead:

```bash
gc slack publish-to-channel --conversation-id <channel-id> --kind room \
  --session "$GC_SESSION_ID" --body "..."
```

## Posting a status update under the bot identity

```bash
gc slack post-message --channel <channel-id> --kind milestone \
  --payload '{"title":"...","summary":"..."}'
```

`post-message` bypasses session bindings and posts directly with
`SLACK_BOT_TOKEN` — but it does not inherit that token from `gc`'s own
environment. Source the adapter's env file in a subshell first:

```bash
( set -a; source ~/.config/gc-slack-adapter/env; set +a
  gc slack post-message --channel <channel-id> --kind milestone --payload '...' )
```

Posting to a user id (`U…`) instead of a channel id delivers into the bot's
1:1 DM with that user and returns the DM's channel id (`D…`) — expected
behavior, not a failure.

## Delegating to a peer agent

Company-room mode only (see below):

```bash
gc slack delegate --turn-ref <turn_ref> --to <agent> --body-file <path>
```

Valid only from a human-rooted turn (`ambient` / `thread_ambient` /
`targeted`); a delegated turn cannot itself redelegate. One pending
delegation per peer per thread — cancel a dead one first
(`gc slack delegate --turn-ref <turn_ref> --cancel --to <agent>`).

## Checking state

```bash
gc slack status --session "$GC_SESSION_ID"   # your bindings + recent traffic
gc slack peers                                # company-room directory + wake policy
```

There is no `gc transcript` command in this CLI (it is not a top-level `gc`
verb at all). If a runbook or reminder tells you to run `gc transcript read
--ack`, skip it — use `gc slack status` or `gc events --type
extmsg.inbound` to check inbound state instead.

## Two conversation models — don't mix their rules

- **Plain `bind-dm` / `bind-room`** — one session (or a small explicit group)
  bound to one conversation. Use `reply-current` / `publish` / `react` with
  explicit `--conversation-id` as shown above.
- **Company rooms** (the `slack-v0` prompt fragment; `peers` / `delegate` /
  `company-status`) — conversations addressed by an immutable `turn_ref`,
  with wake kinds (`ambient` / `targeted` / `peer_delegation` / `peer_result`
  / ...) telling you whether to respond at all.

If your agent runs in plain `bind-dm`/`bind-room` mode, don't borrow the
`slack-v0` fragment's reply instructions (they assume `turn_ref`s exist) —
use the explicit `--conversation-id` / `--reply-to` form instead.

## Setting up a binding (usually a mayor/operator task)

```bash
gc slack bind-dm <D-channel-id> <session-or-alias>
gc slack bind-room <C-channel-id> <session1> [<session2> ...] \
  (--binding-owner <session> | --group-only)
```

`bind-room` always requires exactly one of `--binding-owner` / `--group-only`
— there is no default. `--group-only` is destructive: it removes *every*
existing direct binding for that conversation, including ones set by other
tooling, so it is never assumed silently.

## Scope: this skill is global, on purpose

This file lives under `pack/skills/gc-slack/` — inside the con-voyage GC
pack itself (`packs/con-voyage/skills/gc-slack/` once cast), the same
directory shape the bundled `core` pack uses for `core.gc-mail` /
`core.gc-work`. Once a city runs `gc import add ./packs/con-voyage`, `gc`'s
own skill materializer picks this up as a binding-qualified shared skill
(`con-voyage.gc-slack`) and serves it to every agent's provider skill
sink — mayor, workers, and reviewer lenses alike.

That is deliberately different from the mold's *other* `skills/con-voyage/`
directory (mold root, sibling to `pack/`, mapped by `flux.yaml` to
`.claude/skills/con-voyage`). That one is a thin `/con-voyage` launcher for
human Claude Code sessions only — it is never part of the imported pack and
never reaches a non-Claude-Code agent. A skill meant for every agent in the
city belongs under `pack/skills/`, not mold-root `skills/`.
