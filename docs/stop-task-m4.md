# STOP — Milestone 4 (Fees / Direct / CTO)

**Branch:** `milestone-4`  
**Date:** 2026-07-25  
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
| *(this)* | docs(m4): STOP + initiator-as-CTO-winner clarification |

## Local gate

- Reference: unchanged (auction math untouched)
- Unit/vector bucket: **102 passed**
- 200-vector fuzz seed 4663: **PASS**
- Invariant campaign: **11/11**
- M4 C1–C4 suites: **27/27** (C1 provisional on mock)

## Spec surface for review

Primary doc: [`docs/fees-and-governance.md`](fees-and-governance.md)

- Hook-based primary fees (Doppler/Bankr parity); best-effort; 80/20
- Direct $4k/$8k; rug-impossible; emergent tier volatility
- Checkpointed token; CTO with protective rationale verbatim
- FeeLocker v2 for new launches; side-pool compounding unchanged

## Ruling ask (one ambiguity resolved in code — confirm)

On CTO **pass**, feeReceiver + page-admin transfer to the **initiator**
(candidate who opened the vote). Spec said "winner" without defining it;
documented in fees-and-governance §4.4. Confirm or rule otherwise.

## Provisional / parallel

- M4 C1 (hook) provisional on mock → re-run unmodified vs real v4 in **M3.5**
- M3 C1/C2/C3-partial remain provisional per M3 review
- Deployment ladder D2/D3 still block testnet

## Ask of the human

1. Confirm fees-and-governance framing (hook discipline, 80/20, CTO rules).
2. Confirm initiator-as-winner on CTO pass (§4.4).
3. On remote CI green: approve merge. M4 done; M3.5 and/or next milestone next.
