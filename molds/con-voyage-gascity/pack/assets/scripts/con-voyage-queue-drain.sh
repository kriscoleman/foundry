#!/usr/bin/env bash
# con-voyage-queue-drain.sh — order entry point for the con-voyage
# concurrency queue: `cv-sling.sh drain`. A no-op (no gc calls) when nothing
# is queued, which is always the case in a city with no cap configured. See
# cv-sling.sh for the cap, the queue, and the fail-closed rules.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cv-sling.sh" drain
