# Security Policy

## Reporting

Email **security@stonkz.green** with a clear description, affected contracts/addresses, and a proof of concept when possible. Do not open public issues for undisclosed vulnerabilities.

We aim to acknowledge within **2 business days** and to triage severity within **7 days**.

## Scope (in)

Primary launch surface on Robinhood Chain (id **4663**):

- `StonkzFeeHook` (BeforeSwapDelta fee take + accrue/flush)
- `StonkzLadderAuction` / `StonkzLadderFactory` / `LadderSettlement`
- `StonkzVault`
- `StonkzExpressFactory` / `StonkzDirectListing`
- `FeeLockerV2`, `V4Adapter`, `DeployControls`, `StonkzToken` (protocol token)

External Uniswap v4 / Robinhood PoolManager, Universal Router, and Permit2 are **out of scope** except for integration bugs in our adapter/hook wiring.

## Out of scope

- Issues that require compromised private keys, phishing, or social engineering
- Third-party frontend/RPC/wallet bugs without a smart-contract root cause
- Known guarded-launch caps (raise / TVL / `maxUniqueActives`) behaving as designed
- MockPoolManager / test-only paths
- Gas griefing that does not corrupt funds or break invariants

## Bounty tiers (day-one)

Paid in USDC (or equivalent) on Robinhood Chain / Ethereum as agreed. Caps scale with treasury; figures below are **launch floors**.

| Severity | Examples | Reward |
|---|---|---|
| **Critical** | Direct theft of user funds / LP / vault principal; permanent freeze of user assets; unauthorized mint of launch or protocol token | **$25,000 – $100,000** |
| **High** | Incorrect settlement / fee take that drains material value; bypass of DeployControls soft-launch gate on production; hook fee accounting that steals across pools | **$5,000 – $25,000** |
| **Medium** | Griefing that forces incorrect graduation/refund paths; material invariant break without immediate theft; vanity / CREATE2 prediction mismatches that enable grief | **$1,000 – $5,000** |
| **Low** | Informational / defense-in-depth; non-exploitable correctness issues with clear impact | **$100 – $1,000** |

Severity follows impact × exploitability. Duplicate reports: first clear report wins. Public disclosure before a fix lands voids the bounty unless we agree in writing.

## Safe Harbor

Good-faith research that stays within this policy and does not degrade mainnet availability is authorized. We will not pursue legal action against researchers who follow this process.

## Deployment posture

- Contracts are **immutable** (no upgrade proxies).
- Soft-launch: `DeployControls` closed + deployer-only until opened.
- Production binds to Robinhood PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951` via `V4Adapter`; hook address mined `0x4663` + flags `0x088`.
