# 0001 — Segment identity is frozen when the segment is created

Status: accepted 2026-10-26 (#20)

## Context

Spec T4 says a segment's first line holds the app version / build / name + `device_id` "at seal time". The outbox only appends, so writing the identity at seal time would mean rewriting the file's first line.

## Decision

The identity line is written when the segment is created, as its first line, and the envelope uses it at send.

## Consequences

- Within one process, creation and seal see the same identity: an app upgrade restarts the process, and `reset()` (the only thing that rotates `device_id`) clears the outbox.
- A segment left open by a killed process is sealed on the next launch and keeps the build that wrote its events. That's the R14 intent. Sealing at launch would stamp it with the new build.
- iOS (#24) follows the same rule.
