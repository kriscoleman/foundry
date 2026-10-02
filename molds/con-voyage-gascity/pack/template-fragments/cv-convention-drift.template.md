<!-- cv-convention-drift: convention-drift checklist shared by the two
     frontend-focused lenses (cv-frontend-principal-engineer, cv-design-ux)
     — loaded by the gc template engine. Keep this section here once; do not
     paste it into each lens's own prompt.template.md. -->
{{ define "cv-convention-drift" }}
## Convention-drift check — verify explicitly

Compare every NEW or changed UI element against its nearest siblings (same
panel/page/component family) and the repo's design tokens and shared
components — not just against itself.

1. **Class tokens** — radius, border, color, spacing, and typography must
   match the convention already used by this element's siblings. A
   justified deviation is still drift: report it at least LOW, with the
   justification noted as context, not as an exemption from reporting.
2. **Component reuse** — a new element that duplicates an existing shared
   component instead of reusing it is drift, not a style choice.
3. **Copy and verb consistency** — new copy (labels, messages, actions)
   must match the verbs and phrasing already established for the same
   action elsewhere in the product.

Every drift is a finding with the changed `file:line`, the established
convention it breaks (cite the sibling's `file:line`), and the exact fix —
even when the deviation is justified, cite both file:lines and note the
justification as context.

Severity — decide in this order:
- **BLOCKING**: the diff forks an existing shared component instead of
  reusing it (a duplicate implementation becomes a second source of truth).
- **LOW**: all other drift — whether visible to users, diverging from shared
  components, or elsewhere in the checklist.
{{ end }}
