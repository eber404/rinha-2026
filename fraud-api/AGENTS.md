# fraud-api Agent Notes

## Scope

This directory contains the Zig fraud API service used behind the Zig load balancer.

## Rules

- Keep request handling allocation-free in hot paths.
- Prefer direct byte parsing for HTTP and payload extraction.
- Keep endpoint contracts stable:
  - `GET /ready`
  - `POST /fraud-score`
- Avoid introducing Bun/Node runtime code in this service path.

## Validation

- Build check: `zig build-exe src/main.zig -O ReleaseSmall`
- Integration check: run through docker-compose from repository root.
