# Morpheus DepositPool — Self-Referral PoC

Foundry proof-of-concept for a self-referral issue in the Morpheus
`DepositPool` (stETH, pool 0) on Ethereum mainnet.

## Finding (summary)

`DepositPool.stake()` accepts any `referrer_` with no check that
`referrer_ != msg.sender` and no requirement that the referrer ever staked
(`DepositPool.sol:251/392/605`, `ReferrerLib.sol:11/30`). A staker who refers
themselves earns referrer-tier weight (up to 15%) plus the +1% referral
multiplier on their own capital. `claimReferrerTier()` can also be claimed
without ever staking (`DepositPool.sol:294/568`). The extra MOR is dilution:
it comes out of other pool-0 stakers' rewards.

Demonstrated: a 1,000 stETH staker gains +1,125.45 MOR in 31.25 days
(+14.26% vs baseline); a 100 stETH staker loses 11.83 MOR in the same window
(−1.50%). An existing position can be flipped to self-referral retroactively
with a 0.01 stETH re-stake.

Deployed implementation (Sourcify `match`):
`0xdb10daef167ea2233ba6811457dd24d676fbd670` behind DepositPool proxy
`0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790`.

## Run

```sh
forge test --match-contract SelfReferralTest -vv
```

Expected: **3 passed, 0 failed**

- `testBaseline_NoReferrer` — no referrer: attacker 7,891.541 MOR.
- `testAttack_SelfReferral` — self-referral: attacker user 7,850.999 MOR +
  referrer 1,165.990 MOR = 9,016.989 MOR; both `claim()` and
  `claimReferrerTier()` succeed on the fork (LayerZero send accepted).
- `testRetroactiveSelfReferral` — a 0.01 stETH re-stake attaches the whole
  existing 1,000 stETH position to self-referral
  (`amountStaked` 1,000.01 stETH, virtual 150.0015 stETH).

Pinned fork: Ethereum mainnet block **26,428,955**
(`[rpc_endpoints] mainnet` in `foundry.toml`, public RPC).

## Notes on the test setup

- Only the six out-of-scope Chainlink feed contracts are mocked, to return
  their real answers with fresh timestamps (on a fork the feeds stop updating
  and `distributeRewards` reverts on the 3,600 s staleness check). All
  in-scope contracts (DepositPool, Distributor, RewardPool,
  ChainLinkDataConsumer, L1Sender) run unmodified at their deployed
  addresses.
- stETH does not rebase on a fork (no Lido oracle reports), so 30 days of
  Lido yield (~3% APR) is simulated by stETH donations to the Distributor —
  the protocol's own balance-delta yield accounting. The +14.26% figure is
  set by the weight ratio, not by the yield size.
- Attacker/victim stETH comes from the Curve stETH/ETH pool via local fork
  pranks (no keys, no privileged accounts).

## Suggested fix

Reject `referrer_ == msg.sender` in `_applyReferrerTier()` / `stake()`;
optionally require the referrer to have staked in the same pool first.
