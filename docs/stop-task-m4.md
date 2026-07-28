# STOP — Milestone 4 (Fees / Direct / CTO)

**Branch:** `cto-ruling-amendments` (from `main` @ `4328c1d`)  
**Date:** 2026-07-25  
**Status:** **MERGED** @ `94ad73c` (PR #5). Closed.
**Protocol:** push-before-ruling. Complete only after push + remote CI green.

## Precondition

| | |
|---|---|
| M3 → main | [PR #2](https://github.com/trudeaudm/stonkz.green/pull/2) `21eaf1b` |
| M3 CI | https://github.com/trudeaudm/stonkz.green/actions/runs/30164150582 |
| M3 review findings | [PR #3](https://github.com/trudeaudm/stonkz.green/pull/3) `b04b61d` |
| M3.5 | May run in parallel; still required before testnet |

## Commits

| Hash | Summary |
|---|---|
| `3d53fa6` | docs(m4-a): fees-and-governance — hook fees, direct listing, CTO |
| `c815c12` | feat(m4): direct-to-DEX + hook fee architecture + CTO governance |
| `2b5c3a9` | docs(m4): STOP (pre-ruling; initiator-as-winner — superseded) |
| *(this)* | CTO ruling amendments: explicit candidate + restructured cooldown |

## Local gate

- Reference: unchanged (auction math untouched)
- Unit/vector bucket: **102 passed**
- 200-vector fuzz seed 4663: **PASS**
- Invariant campaign: **11/11**
- M4 C1–C4 suites: **31/31** (was 27 at STOP; +4 C3 amendment tests at merge — C1 provisional on mock)

## Spec surface for review

Primary doc: [`docs/fees-and-governance.md`](fees-and-governance.md)

- Hook-based primary fees (Doppler/Bankr parity); best-effort; 80/20
- Direct $4k/$8k; rug-impossible; emergent tier volatility
- Checkpointed token; CTO with protective rationale verbatim
- FeeLocker v2 for new launches; side-pool compounding unchanged

## Ruling ask (RESOLVED)

On CTO **pass**, feeReceiver + page-admin transfer to the **candidate**
(explicit beneficiary at initiation; default = initiator). Confirmed with
amendments 2026-07-25: candidate immutable per vote; 7d cooldown binds
failed initiator+candidate addresses; token spacing is 24h (squatter rationale).

## Provisional / parallel

- M4 C1 (hook) provisional on mock → re-run unmodified vs real v4 in **M3.5**
- M3 C1/C2/C3-partial remain provisional per M3 review
- Deployment ladder D2/D3 still block testnet

## Ask of the human

1. ~~Confirm fees-and-governance framing~~ — confirmed.
2. ~~CTO pass beneficiary + cooldown~~ — confirmed with amendments (§4.1 / §4.4 / §4.5).
3. ~~On remote CI green: approve merge of `cto-ruling-amendments`~~ — **MERGED** @ `94ad73c`. M4 closed; M3.5 and/or next milestone next.
