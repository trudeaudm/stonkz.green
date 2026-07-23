# Task F — Rounding-direction fixes (applied)

Guarantee: **protocol never underflows; bidders never overdrawn.**

| Site | Was | Now | Rationale |
|------|-----|-----|-----------|
| Fill cost `take×price` | floor mulWad | floor (unchanged) | Never charge past `budLeft` |
| `raised` update | `mulWad(soldNow, price)` | Σ per-fill costs | Same rounding as charges; enables Task G |
| Top-up `needNow` | floor | **mulDivUp** | Conservative reserve need |
| Top-up `futureNeed` | floor | **mulDivUp** | Conservative headroom |
| Top-up `drain` | floor | floor (unchanged) | Prefer underselling reserve |

Vectors re-run after flips; per-block tolerances (Task I) expected to absorb dust.
