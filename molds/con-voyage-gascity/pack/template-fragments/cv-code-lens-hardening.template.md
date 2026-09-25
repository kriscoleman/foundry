<!-- cv-code-lens-hardening: #10494-class regression checklist shared by the
     three code-lens variants (go / frontend / generic) — loaded by the gc
     template engine. Keep items 1-4 here once; do not paste them into each
     lens's own prompt.template.md. -->
{{ define "cv-code-lens-hardening" }}
## Hardening checklist — you must verify explicitly (BLOCKING)

These four checks exist because con-voyage's own lenses previously waved
through changes with these exact gaps. Treat each as a required check you
perform on every review, not a nice-to-have — a miss on any of them is a
BLOCKING finding.

1. **Path coverage — verify explicitly.** When the change threads a new
   parameter or behavior, enumerate every live code path that consumes the
   related input (e.g. the portal/UI flow, the headless or service-account
   flow, any legacy-update flow) and confirm each one actually threads it.
   Any live path that drops it is BLOCKING. An intentionally-unthreaded path
   is acceptable ONLY with an explicit tracking comment AND a live-caller
   check you perform yourself — trace the route registration or call graph;
   a comment's claim of "no live caller" is not itself proof.
2. **Exported-signature break — verify explicitly.** Flag any change to an
   exported function/method signature or public interface. New behavior must
   thread via optional parameters/options, never by changing an existing
   signature. Verify existing callers still compile/typecheck unchanged.
3. **Silent fallback — verify explicitly.** Flag any swallowed error, silent
   fallback, or degraded output produced on failure. A resolution or
   validation failure must fail loud, not silently emit degraded (e.g.
   unnamespaced) output. An intentional drop-with-warning is acceptable only
   when the diff explicitly specifies it (a logged warning and a surfaced
   warning signal) — a silent drop with no signal anywhere is BLOCKING.
4. **Cache-key completeness — verify explicitly.** Every output-affecting
   input — including per-item/per-chart rules, and values that are discarded
   rather than applied — must be part of any cache key that gates that
   output. A cache key missing an output-affecting input produces a stale,
   incorrect result served to a sibling request. Check every cache or
   memoization guard the diff touches, not just the most obvious one.
{{ end }}
