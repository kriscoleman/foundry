# CI failure test (temporary)

This file exists only to make CI fail on purpose so CI behavior can be tested.

It contains a deliberately broken relative link, which the
`Check markdown links` step in `.github/workflows/mold-validate.yml` rejects:

[this target does not exist](./this-file-does-not-exist.md)

**Do not merge.** Delete this file (or close the PR) once the test is done.
