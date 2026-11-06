> Historical review coverage, preserved for regression testing. Names and default timing now
> follow HamsterNap3D; this is not an independent review of the core-migration changes. See
> `docs/CORE_MIGRATION.md` for the new implementation and pending review scope.

# Independent Hamster Nap tests

These tests supplement the accepted implementation's suite. Production contracts,
configuration, dependencies, and ABI exports are unchanged.

| File | Coverage |
| --- | --- |
| `HamsterNap3D.independent.t.sol` | 1,000 fuzz cases at the last-second/first-second boundary; dust before and during a nap; delayed third-round certification; interrupted zero runs; multiple naps spanning page boundaries; atomic rollback after a later page reverts; accumulating rejected payouts, failed and repeated withdrawals; failsafe/deferred-debt isolation and recovery; malformed core responses; exact-input/output sells and LP fee collection with an unavailable core; price-limited partial fills (exact input and exact output) on both sides of the boundary second, their refunds to a rejecting sender wallet, a late backlog that restarts the failsafe clock, and sells that cannot move it; a failsafe over a partly readable backlog that pays the certified nap to its own winner first; 512 fuzz cases at the failsafe's rolling cutoff (a buy one second before the opening counts; a buy at or after it wins nothing in front of the call, and is paid its own fee only once it is more than seven days old, to the second); a game opened by dust paying the first later qualifying buyer; a dust fee after a payout reaching the last qualifying buyer. |
| `HamsterNap3D.fork.t.sol` | Five live-core tests at Sepolia block **12030457**, including every captured work record in rounds 483–642, configuration/frontier and invalid page bounds, three historical naps paid in order, and fresh token-only pool claim redemption. |
| `HamsterNap3D.invariant.t.sol` | Two campaigns, each **256 runs × 96 calls**, with unexpected handler reverts treated as failures. One explores ordinary settlement and one also introduces seven-day outages and failsafes. Four deterministic companions prove a deferred payout, withdrawal, failsafe, partial-fill refund, an unseen-advance `CoreNotStale`, a failsafe that settles a certified nap first, and a `NapsUnsettled` refusal over a 160-round backlog, and a second failsafe payout to a buyer who qualified after the first are reachable. |
| `independent/NapSequenceHandler.sol` | Random exact-input/output buys (full and price-limited partial fills) and sells, time advances, append-only certification, reverting/paused core, page-limited settlement, claim redemption, receiver rejection and withdrawals. |
| `independent/SequenceCore.sol` | Efficient offline model of sparse settled-round pages. Only closed rounds can be certified, and certified work never changes. |

The invariant oracle keeps its own linear trade history. It computes fees from actual
ETH debits, determines winners and eligible fees independently of the hook's cumulative
checkpoints, and compares awards to each receiver's ETH plus deferred debt. It also
models partial exact-input fills from the router's actual debit (fee = 2% of the ETH really
spent, the rest of the reservation owed back to `tx.origin`), and keeps its own record of when
a hook call last read a higher frontier, so the failsafe is expected to open seven days after
that sighting (or the sighted round's end) and to revert `CoreNotStale` while an advance is
unseen. For the failsafe it walks the certified backlog itself: more than eight pages (128 rounds)
unscanned must revert `NapsUnsettled` with the exact scan position, otherwise every certified nap is
paid to its own winner first (rolled back with the call if it then reverts `NothingToPay`), and the
fees paid through the last buy strictly before the cutoff (the later of the opening and seven days
ago) that nothing has paid yet go to the last qualifying buyer before that cutoff; `NothingToPay`
when there are none. The recovery campaign also calls the failsafe up to ten days after it opened,
so later payouts over the rolling cutoff are exercised. A reverting core skips the scan. `settleNaps` on an unreadable
core must revert `CoreUnreadable`. It checks the actual PoolManager ERC-6909 balance against `claimsHeld`, fee and refund
conservation, the pot and debt backing, `lastSeenFrontier` / `frontierSeenAt`, scan progress,
nap counts, and NAP supply/balances. The handler
does not catch unexpected errors. A deterministic companion proves that a deferred
payout, successful withdrawal, and failsafe are reachable.

The inherited test router is a prefunded simulation: trader identities are pranked
while settlement comes from the router. Contract origins model a sender wallet with
code (for example delegated-account behavior); the workflow explicitly selects
`tx.origin` as the buyer. These helpers are not production routers.

## Fork and offline execution

The archival fork suite now uses a fork supplied through Foundry command-line flags:
`--fork-url <archive-endpoint> --fork-block-number 12030457`. With no active fork it skips.
A supplied fork must have the exact chain and block. Tests read and write no environment
variables; no endpoint or key is stored in the repository. A test-only hook constructor
restores the original proxy and genesis literals for this historical replay. The new
production hook is tested offline against the updated default timeline and mutable mock.

The live SqueekCore proxy is never etched, mocked, or given altered storage on the
fork. Historical buys use local timestamps over the fixed live ledger; they do not
roll to another block. The PoolManager, token, hook, and router are locally deployed.
The ordinary suite and captured-round replay remain fully offline.

Run with the assignment seed:

```sh
FOUNDRY_FUZZ_SEED=0x78af848289a6cfdfe3ce352b08b7f4d056e64612920bbac37985ea48ca384cc2 forge build
FOUNDRY_FUZZ_SEED=0x78af848289a6cfdfe3ce352b08b7f4d056e64612920bbac37985ea48ca384cc2 forge test
```

## Findings from the previous round, settled

Both high-severity findings reported last round are fixed in the current tree, and these tests
check the fixes rather than restating the findings:

1. **Partial exact-input dust fills.** The fee and the 0.001 ETH threshold now follow the pool's
   fill; the unused reservation is credited to the buyer. Checked by
   `test_partialFillsAroundTheBoundaryFollowExecutedEth` (a dust fill offering 1 ETH in the last
   second before round 651 cannot displace Alice, who receives exactly the fees before 651),
   `test_partialRefundToRejectingOriginIsHeldAndDoesNotBlockNap`, and the `buyLimited` handler
   action in both invariant campaigns.
2. **Failsafe dated from the round end.** The failsafe now counts from the hook's last sighting of
   a frontier advance. Checked by `test_lateBacklogSeenByClaimRestartsFailsafeClock`,
   `test_onlyBuysAndClaimsMoveFailsafeClock` and the recovery campaign's observation-dated model.

## Finding from the previous round, settled

**Failsafe winner frozen at the first opening** (medium). The author fixed it with a rolling cutoff,
max(`failsafeOpensAt()`, now − 7 days), and now pays only the fees through the winner's last buy
before that cutoff. These tests check the fix against both cases of the reproduction:
`testFuzz_failsafeWinnerBoundary` (a later buyer is paid its own fee exactly once at 7 days + 1
second, the earlier winner nothing more), `test_failsafeOpenedByDustPaysLaterQualifyingBuyerAfterSevenDays`
(a dust-only opening refuses `NoQualifyingBuyer` until the buy is more than seven days old, then pays
the whole pot), `test_failsafeDustFeeAfterPayoutReachesLastQualifyingBuyer`, and the recovery
campaign's `takeFailsafeAfterExtraWait` action, which models the rolling cutoff independently. A buy
placed in front of the call still takes nothing. No new finding this round.

## Remaining limits (not defects)

- The hook cannot learn when the core really advanced, so the failsafe can open up to seven days
  late, never early. An advance that only the `failsafe()` call itself finds reverts with
  `CoreNotStale`, and that revert also undoes the sighting. So the failsafe stays shut until a buy
  (dust is enough) or a `settleNaps` call records it. That is the conservative direction, and a
  way out always exists, because buys read the core even when `roundPage` does not work. The one
  exception, added in the third revision, is a core whose frontier reads while its next page does
  not: that `failsafe()` call records the page failure instead of reverting (keeping the sighting),
  and the failsafe opens seven days after the record. The handler's core fails both reads
  together, so this path is covered by `HamsterNap3D.recovery.t.sol`, not by the campaigns.
- If the core advances and then starts reverting before any hook call sees the advance, the hook
  dates the failsafe from its last successful sighting. This is the documented exit for a dead core.

Passing tests do not imply launch readiness.
