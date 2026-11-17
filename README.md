# Morpheus SessionRouter — provider approval not bound to the user (PoC)

Foundry proof of concept for a bug-bounty report to Morpheus
(`devs@mor.org`, program v2 eff. 2026-08-07).

## The bug

`SessionRouter.openSession` (LumerinDiamond
`0x6aBE1d282f72B474E54527D93b979A4f64d3030a` on Base, SessionRouter facet
`0x3a3952f0E57b343F00b31F7dA039eF16389B7260`) accepts any provider-signed
session approval regardless of which user the approval names.
`_extractProviderApproval` decodes the approval tuple
`(bidId, chainId, address, timestamp)` but **discards the address field**
and never compares it to `openSession`'s `user_` parameter. The error
`SessionApprovedForAnotherUser` exists in the interface but is never thrown.

Anyone who observes a victim's approval (e.g. in the mempool, where the
victim's `openSession` tx is public) can front-run it, open a session for
themselves against the provider's bid, and burn the one-time approval —
the victim's `openSession` then reverts with `SessionDuplicateApproval`.

## Run

```bash
BASE_RPC_URL=https://mainnet.base.org forge test --match-contract SessionApprovalNotBoundToUser -vvv
```

No setup beyond an RPC URL. The test runs against a Base mainnet fork
pinned to block **58549310** and asserts the broken invariant directly:
a provider approval naming user X is usable by any other user Y.

Expected result: `[PASS] testApprovalCanBeStolenByAnotherUser()`.

`forge-std` is vendored under `lib/forge-std/` (MIT) so the repo is
self-contained — no submodule setup needed.

## Fix

Bind the approval to the session user: pass `user_` into
`_extractProviderApproval` and revert with the (existing)
`SessionApprovedForAnotherUser` error when the decoded address differs
from `user_`. Compare against the `user_` parameter, not `msg.sender`,
so provider-delegated opens keep working.
