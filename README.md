# Hamster Nap 3D (NAP)

A last-buyer-before-bedtime game on Squeektoshi, SqueekChain's real hamster, as one Uniswap v4
hook on Ethereum Sepolia. Every buy of NAP pays 2% of its ETH into a pot the hook holds. A buy
spending at least 0.001 ETH makes its buyer the latest qualifying buyer. When SqueekCore certifies a nap, the last buyer before the nap began
takes the pot. An unofficial community game with Sepolia test tokens of no value, not affiliated
with SqueekChain.

This repository is the contract stage: the token, the hook, their tests and ABI documentation.
The launch (publish, attest, admit, deploy) and the website come after it. The existing
`launch.json`, `web/deployment.handoff.json`, `dist/` and `docs/frontend/` describe an earlier
deployment; they are not deployment evidence for HamsterNap3D. The separate manifest assignment
must replace that manifest, and the website assignment must refresh the site after deployment.
This source contribution changes contracts, tests and contract documentation only.

## What the launch deploys

| Contract | File | Constructor arguments |
| --- | --- | --- |
| `NapToken` | `src/NapToken.sol` | none |
| `HamsterNap3D` | `src/HamsterNap3D.sol` | `IPoolManager poolManager` = `$poolManager`, `address factory` = `$factory`, `address owner` = `$owner` |

`NapToken` is the standard launch token: name "Hamster Nap 3D", symbol "NAP", 18 decimals,
exactly 1,000,000,000 tokens (10^27 minor units) minted once to its deployer, the launch factory.
No owner, mint, pause, blocklist, fee or upgrade. The brief asks for nothing else of the token;
the game's fee is the hook's.

`HamsterNap3D` takes an explicit, nonzero owner in its third constructor argument. For this
launch `$owner` resolves to `0x887b86b6b6957f7bbea88b8cefd392f39236a88c`. The factory and the
transaction origin acquire no owner rights. The owner's only privileged calls are `setCore`
and `finalizeCore`; there is no ownership transfer, renunciation, pause, upgrade, fee change or
pot withdrawal. See **Core replacement and finalization** for the trust this entails.

The pot is the hook itself (its ETH balance plus any ERC-6909 ETH claims on the PoolManager),
exposed through `pot()`; there is no third deployed helper. Both constructors make no external
calls. The PoolManager and factory are constructor parameters supplied by the launch services,
not hardcoded chain addresses. ABI exports are `docs/abi/HamsterNap3D.json` and
`docs/abi/NapToken.json`.

Pool terms the manifest step writes: native ETH pair (`pairedCurrency` zero), LP fee 12500
(1.25%), tick spacing 60. The hook accepts any LP fee the factory opens the pool with; it checks
only that the sender is the factory, that the pool is paired with native ETH, and that no pool is
bound yet. The deployer sets the opening price.

## Hook configuration

Permissions, in the OpenZeppelin Wizard's shape:

```json
{
  "hook": "BaseHook",
  "name": "HamsterNap3D",
  "pausable": false,
  "currencySettler": false,
  "safeCast": true,
  "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true,
    "afterInitialize": false,
    "beforeAddLiquidity": false,
    "afterAddLiquidity": false,
    "beforeRemoveLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": true,
    "afterSwap": true,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": true,
    "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "access": "ownable",
  "info": { "license": "MIT" }
}
```

The ownership guard is implemented with an immutable owner and exactly two admin methods;
it does not inherit ownership-transfer or renunciation entry points.

Address flags: `0x20CC` (8396). The hook's address must carry exactly these bits; the deployer
mines the CREATE2 salt, and the tests mine one the same way.

Callbacks and why each is there:

- `beforeInitialize` (added for the launch): only the launch factory (`$factory`) may open the
  pool, once, paired with native ETH. It binds the pool id and reads the token from the PoolKey.
  Nobody can open the predicted pool before the factory deploys the hook.
- `beforeSwap` + `beforeSwapReturnDelta`: on an exact-input buy the fee is carved out of the
  specified ETH input, so the pool swaps the remaining 98%. Runs the mainnet-only Sworn check.
- `afterSwap` + `afterSwapReturnDelta`: on an exact-output buy the fee is added to the ETH the
  buyer pays (the unspecified side). For both buy kinds this callback collects the fee in ETH,
  records the buy, updates the latest buyer and observes the core's frontier.
- No remove-liquidity callbacks: the factory's fee collect (a zero liquidity change) passes
  untouched. Every callback refuses callers other than the PoolManager.

`BaseHook` is a minimal base of our own in `src/base/BaseHook.sol` (the current v4-periphery no
longer ships one); it validates the address flags in the constructor and calls no other contract.

## The game

Rules as implemented, with the constants in `HamsterNap3D`:

1. **Buy fee.** A buy (ETH in, NAP out; ETH is always `currency0`) pays `FEE_BPS` = 200 basis
   points, 2% of the ETH the buyer really spends, fee included. Exact input: `beforeSwap` reserves
   2% of the offered input and the pool swaps the other 98%; `afterSwap` reads the ETH the pool
   actually consumed from the pool's own delta. On a full fill the fee is the reservation. On a
   partial fill (a price limit or exhausted liquidity left part of the input unused) the fee is
   pool ETH × 200 / 9800, 2% of the executed gross, and the unused part of the reservation is
   credited to the buyer in `owed` (event `FeeRefunded`), pulled with `withdrawOwed()`. Nothing is
   pushed to anyone during the swap, so the refund cannot fail or be griefed. Exact output: fee =
   pool ETH × 200 / 9800 on the ETH actually paid, so a partial fill is right by construction.
   Sells pay no game fee. The fee is settled in ETH inside the swap: the hook takes native ETH
   when the PoolManager's ETH balance covers it, and mints itself an ERC-6909 ETH claim when it
   does not (a fresh manager or a pool seeded with tokens only). Claims are redeemed into ETH
   before any payout, and anyone may call `redeemClaims()`. Nothing is ever left in NAP.
2. **Latest buyer.** A buy whose executed gross (pool ETH plus fee) is at least
   `MIN_QUALIFYING_BUY` = 0.001 ETH makes the transaction's sender wallet, `tx.origin`, the latest
   buyer, as the brief specifies. The input a buyer offered but the pool did not use counts for
   nothing: a 0.001 ETH order that fills for a sliver is a dust buy. Smaller buys still pay the fee
   into the pot. Both its timestamp and the round on the then-active core are recorded.
3. **Nap.** `NAP_ROUNDS` = 3 consecutive settled rounds with zero work. It begins at its first
   zero-work round `s`. A run of more than three zero-work rounds is one nap and pays once; the
   next nap can only begin after a round with work.
4. **Winner and pot.** The winner of the nap at `s` is the latest qualifying buyer as of the last
   buy recorded strictly before `roundStart(s)` on the active core. The pot paid is all fees from
   buys before that timestamp that have not been paid out yet. Historical round numbers may
   decrease across core changes, so winner selection binary-searches timestamps, never rounds. Fees from buys during or after the nap stay for the next
   game. If no qualifying buyer existed before `s` (dust only), the nap settles with no payout and
   the pot waits.
5. **Claim.** `settleNaps(maxPages)` may be called by anyone. It reads `state()` for the certified
   frontier and `roundPage` 16 rounds at a time from the last scanned round, pays every nap found
   in order, and keeps its position between calls, so a long gap can be worked through in several
   transactions. A nap whose third round is not yet certified waits. When `state()` cannot be
   read (it reverts, has no code, no longer decodes, or reports a frontier for a round that has
   not ended) the scan runs through `lastSeenFrontier`, the last credible frontier the hook saw,
   so naps the hook saw certified stay payable while `roundPage` still answers. The call reverts
   with `CoreUnreadable`, keeping nothing, when a page cannot be read (`roundPage` reverts, no
   longer decodes, or certifies nothing from the scan position) or when `state()` cannot be read
   and no round the hook saw certified is left to scan.
6. **Winners that cannot receive ETH** are credited in `owed` and pull with `withdrawOwed()`.
   The game never blocks on a payout: the payout call gives the winner's wallet a bounded
   `PAYOUT_GAS` = 100,000 gas (plus the EVM's 2,300 for a value transfer) and copies none of its
   return data, so a wallet that reverts, burns gas or answers with a payload sized to its gas
   (an EOA carrying EIP-7702 code can do all three) only fails its own payout and is credited.
   `withdrawOwed()` forwards all gas, so a wallet that needs more than the stipend collects
   there. `owed` also holds partial-fill fee refunds (rule 1).
7. **Failsafe.** When the core's `settledThroughRound` has stood still for `FAILSAFE_DELAY` =
   7 days, `failsafe()` pays the failsafe winner: the last qualifying buyer whose buy happened
   before the failsafe's cutoff, `failsafeCutoff()` = max(`failsafeOpensAt()`, now − 7 days).
   It pays the fees collected through that buyer's last recorded buy before the cutoff that are
   not yet paid out; fees from later buys stay in the pot. Anyone may trigger it; only that buyer
   is paid. A buy after the cutoff pays its fee into the pot but cannot take the failsafe
   position now, so the pot cannot be sniped with a 0.001 ETH buy placed ahead of the failsafe
   call; it still counts as a normal buy for the next nap if the core turns out to be alive. The
   cutoff rolls forward with time while the core stands still, so if the core never returns the
   failsafe can be called again: seven days after a later buy, its fee (and any dust fees since
   the previous payout) goes to the buyer who was the last qualifying buyer when it was paid, and
   a buyer who first qualified after the opening is paid once their buy is seven days old. No
   fee is ever locked and no earlier winner is paid twice. `failsafeWinner()` shows who the
   failsafe would pay now and how much; `NothingToPay` means nothing is payable yet.
   Before paying, the failsafe settles every nap the core certified before it stalled, through
   `lastSeenFrontier`, each to its own winner, so a nap that nobody claimed during the stall is
   not swept into the failsafe: it scans up to `FAILSAFE_SCAN_PAGES` = 8 pages (128 rounds, about
   21 hours) itself and reverts with `NapsUnsettled(scanRound, frontier)` when more is pending,
   in which case `settleNaps` must catch up first. When the core's pages cannot be read at all
   (a reverting, codeless or re-ABI'd core), nothing in the backlog can be certified and the
   fees through the cutoff all go to the failsafe winner.
   The hook sees the frontier only when it reads the core (every buy,
   every claim call and the failsafe itself), so it dates staleness conservatively from
   `frontierSeenAt`, the moment it last saw the frontier advance, or from the frontier round's end
   if that is later: the frontier clock is max(`roundEnd(lastSeenFrontier)`, `frontierSeenAt`) +
   7 days. An advance the failsafe call itself finds restarts the 7 days, so a core recovering a
   backlog is never stale however old the rounds it is settling. Until the core has been read once
   (a core unreadable from the start), the clock runs from the game's start, not from genesis. If
   the core reverts, the last frontier and sighting the hook recorded are used. A reported
   frontier for a round that has not ended (at or past `currentRound()`) is not credible, since a
   settled round is over: it is ignored, never clamped, so a core repeating such a report cannot
   keep the failsafe shut or push it out by years.
   A core whose frontier keeps advancing while no page behind it can be read is stale too, or
   nothing could ever pay the pot. A `failsafe()` call that finds the clock shut, `state()`
   readable and the next unscanned page unreadable records that moment in `pageFailureSeenAt`
   (event `PageFailureSeen`) and returns without reverting; from then on the failsafe also opens
   7 days after that record (the page clock), and `failsafeOpensAt()` is the earlier of the two
   clocks. Any certified page a later scan reads clears the record, and a `failsafe()` call whose
   own scan reads a page stays shut unless the frontier clock is open. A dead core (`state()`
   unreadable as well) is the frontier clock's case and records nothing.
8. **First game, mainnet only.** On chain id 1, until the first nap is settled, a buy requires
   `balanceOf(tx.origin) >= 1` on the Sworn registry `0x0da2679000ea5380d1361cc3cca7d4e8c881f766`,
   read live on every buy. On Sepolia and every other chain the check is skipped. Sells always
   work, also when the registry has no code.
9. **Core reads.** Buys read `state()` through a staticcall that tolerates an unreadable core;
   sells never read it. Claims also read pages; `setCore` reads old-core progress and the new
   core's configuration and frontier. Constructors read nothing. Each read is bounded by
   `CORE_READ_GAS` = 5,000,000 gas and the expected ABI's maximum response size (state: 256 bytes,
   configuration: 352, a 16-record page: 2,880). Reverts, exhausted read gas, malformed relevant
   fields or oversized responses count as unreadable. This keeps recovery available if the core
   is upgraded to broken code. Only the fields this game consumes are used. During migration,
   each old-core probe additionally requires enough gas to forward its full budget; insufficient
   caller gas reverts `InsufficientCoreReadGas` and cannot be used to bypass pending naps. Use
   gas estimation for `setCore`; reserved but unused gas is not spent.

Events: `Buy` for every recorded buy (with the executed gross, the fee and `qualifying`),
`NapSettled`, `FailsafeTaken`, `PayoutDeferred`, `FeeRefunded`, `OwedWithdrawn`,
`ClaimsRedeemed`, `FrontierSeen`, `PageFailureSeen(scanRound, frontier, failsafeOpensAt)`,
`GameStarted`, `PoolBound`, `CoreChanged(oldCore, newCore)`, `CoreFinalized(core)`. Both
core-change addresses and the finalized core are indexed.

Views for the website: `pot()`, `latestBuyer()`, `buyCount()` / `buyAt(i)` (round, timestamp,
fees through it, latest buyer then), `winnerBefore(napStart)`, `failsafeWinner()`,
`failsafeOpensAt()`, `failsafeCutoff()`, `pageFailureSeenAt()`, `scanRound()`, `zeroRun()`, `lastSeenFrontier()`,
`owed(wallet)`, `core()`, `coreFinalized()`, `owner()`.
`GENESIS_TIMESTAMP()` and `ROUND_DURATION()` retain their getter names but now read storage.
`roundAt`, `roundStart` and `roundEnd` are now view functions using that stored timing.
`decodeRoundPage(bytes)` is a pure helper the hook calls on itself to read the core's pages
tolerantly; it has no state and nothing to protect.

### Where the ETH goes

Every wei of fee goes into the pot and leaves it only to a nap winner or the failsafe winner.
No administrative share goes to the owner, requester or IMD. The owner may receive only ordinary
winnings or its own owed credit, on the same terms as any buyer. The other ETH the hook holds
is what it owes back: deferred payouts and partial-fill refunds, both in `owed`. Invariant
kept by the tests: `hook ETH balance + claimsHeld == pot() + totalOwed`.

## SqueekCore facts used

The approved workflow supplies the initial live Sepolia proxy
`0xFD6C166D4B8E2962E65746a13e5a0797CD4dE0c4`, followed by the SqueekChain API, and its
configuration measured on 2026-11-06: genesis **1793735400**, round duration **600 seconds**.
These three literal initial values are stored by construction, without calling the proxy.
They were not independently remeasured in this implementation assignment.

Round 1 starts at genesis: `round(t) = (t - genesis) / duration + 1`, with round 0 before genesis.
`state().settledThroughRound` is the certified frontier. `roundPage(after, through, max)` is
start-exclusive, end-inclusive and returns only rounds with work, at most 16 records. A missing
settled round has zero work; rounds past the frontier are unknown. The interface is
`src/interfaces/ISqueekCore.sol`, with the published ABI retained in `docs/abi/SqueekCore.json`.

The older proxy and the captured work ledger in `test/fixtures/SepoliaRounds.sol` are historical
regression fixtures, not this launch's dependency. The offline replay preserves that ledger's
work pattern but uses the new initial genesis. The opt-in archival fork suite uses a test-only
hook with the old initial literals so the earlier live-ledger assertions remain valid.

## Core replacement and finalization

`setCore(ISqueekCore newCore)` is callable only by the fixed launch owner while
`coreFinalized()` is false. It:

1. Checks the old core's current frontier (also respecting a higher previously observed one;
   when `state()` cannot be read, `lastSeenFrontier` stands in for it). If the game has started
   and pending rounds are readable, it reverts with `NapsUnsettled(scanRound, frontier)`.
   Conservatively, **every readable pending round must be scanned**, including worked rounds
   with no nap. Anyone can call `settleNaps` in bounded pages before the owner retries. No payout
   happens inside `setCore`.
2. Allows recovery only if the **next pending page** cannot be read or makes no progress, up to
   the frontier `state()` reports now or, failing that, the last credible one the hook saw.
   Unscanned old rounds are then dropped. A readable prefix must be processed first with
   `settleNaps`; a failure in a later page does not erase a payable earlier nap, and a failure
   of `state()` alone does not drop a nap the hook saw certified while its page still reads. A
   failure of the old `configuration()` alone does not waive settlement, because its timing is
   already cached.
3. Requires the new `configuration()` and `state()` to be readable, with uint64 genesis,
   duration and frontier. Zero duration reverts `InvalidRoundDuration`; a genesis after the
   current block reverts `InvalidGenesis`; a maximal uint64 frontier, or a frontier whose round
   has not ended yet in the new core's own timing (genesis + frontier × duration after the
   current block), reverts `InvalidCoreFrontier`: no honest core has settled a round that is
   not over, and such a timeline would postpone the failsafe. A codeless address or invalid ABI
   reverts `CoreUnreadable`. Failed switches change nothing.
4. Stores the core, genesis and duration; starts scanning at `newFrontier + 1`; empties
   `zeroRun` and `zeroRunStart`; sets `lastSeenFrontier` to the new frontier and
   `frontierSeenAt` to the switch timestamp; clears any recorded page failure; emits
   `CoreChanged`. The seven-day failsafe restarts from the switch (the new frontier's round has
   ended by then, so the switch is the later date). Already-settled new-core history is not
   imported. A switch before the first swap still establishes this scan baseline.
5. Preserves every buy record, the latest buyer, all fees and paid totals, the pot, native claims,
   deferred payouts/refunds, nap count and first-game state. New naps select by buy timestamp
   strictly before their first round's start; a buy before migration can win the first new nap,
   while a buy exactly at that boundary cannot. Previously paid fees cannot be paid again.

`finalizeCore()` is owner-only and one-way. It emits `CoreFinalized(core)` and permanently
blocks `setCore`; repeating it also reverts `CoreIsFinalized`. It changes neither the scan nor
the failsafe clock, balances or trading. Both admin calls share the payout reentrancy lock, so
an owner who wins cannot change the timeline inside a settlement callback. Read dependencies
are reached only with static calls. Same-address reconfiguration before finalization is allowed
and has exactly the same checks and reset behavior as any other switch.

**Trust assumption:** before finalization the owner chooses the source of truth and its timing.
ABI checks cannot prove that it represents the real hamster. An owner can install a dishonest
core to influence which recorded buyer wins, including a buy of their own, drop unreadable
history, or restart the failsafe's seven days with each switch. There is no direct owner
withdrawal, but that does not make core selection harmless: the brief's "nothing goes to the
owner" holds only for an owner who installs the real core. The hook bounds what a switch can
do to the clock (the new timeline must already be running, so a switch can delay the failsafe
by at most seven days, never by years) but adds no timelock, allowlist or delay, because the
brief wants the core changeable until the operator's core is final. The independent review must
assess this power first. Finalization freezes this hook's address
and cached timing, **not** SqueekChain's proxy implementation, reporter or upgrade authority.
Those remain outside trust assumptions. Sells never consult the core and remain available even
if it reverts or after finalization; ordinary pool liquidity and slippage conditions still apply.

## Tests

`forge test` runs the original regression suites plus the new migration suite with
`FOUNDRY_FUZZ_SEED=0x78af848289a6cfdfe3ce352b08b7f4d056e64612920bbac37985ea48ca384cc2`:

- `test/HamsterNap3D.recovery.t.sol`: a core that half works. `state()` unreadable with pages
  readable: `settleNaps` pays a nap the hook saw certified and then reports `CoreUnreadable`
  when nothing seen is left; a 13-page certified backlog refused by the failsafe and worked
  through by `settleNaps(100)` before the failsafe pays the rest; `setCore` refusing
  `NapsUnsettled` over such a nap and going ahead once it is settled or once the page is
  unreadable too. Pages unreadable with the frontier advancing after `finalizeCore`: the
  recording `failsafe()` call (event, no revert, sighting kept), `CoreNotStale` with the
  recorded opening for six days, the payout on the seventh; a readable page clearing the record
  by `settleNaps` and by the failsafe's own scan (which then stays shut and rolls back); nothing
  recorded for a dead core or while the next page reads; the open failsafe settling a readable
  prefix and recording the page behind it. A frontier for the running round, or one 100,000
  rounds ahead, ignored by buys with the clock untouched, and accepted the second its round
  ends; the failsafe opening on time after a far-future misreport. `setCore` rejecting a future
  genesis, a frontier whose round has not ended and a timeline a century out, accepting the
  boundary second and a core at genesis, and restarting the seven days from the switch.
- `test/HamsterNap3D.t.sol`: permissions, callback access, initialization from the factory
  only and once, native pair only; fees on exact-input and exact-output buys, no fee on sells,
  dust buys, the 0.001 ETH threshold, `tx.origin` as the buyer; partial fills against a price
  limit (a 0.001 ETH order that fills for dust pays 2% of the executed ETH, gets the rest of its
  reservation back through `owed`, does not take the latest-buyer position and does not win the
  nap; a partial fill above the threshold still qualifies; a near-zero fill pays nothing and is
  not recorded; a partial exact-output fill; the exact `Buy` and `FeeRefunded` figures; a fuzz
  over offered amounts and limits); the round boundary (a buy in the last second before round `s`
  against the first second of `s`), naps of 2 against 3 rounds, a nap not yet fully settled, a
  long nap paying once, buys during a nap, several naps in one call, pagination, a nap with no
  qualifying buyer; the failsafe (closed, open, shut again when a buy or the failsafe call itself
  sees the frontier advance after eight idle days, dated from the game's start with a core that
  was never readable, with a reverting core, without a buyer; a certified but unclaimed nap paid
  to its own winner before the failsafe pays the rest; `NapsUnsettled` over a 22-page backlog
  until `settleNaps` catches up; the whole pot when the backlog cannot be read from a reverting
  or codeless core; a buy at the moment the failsafe opens, or later, not taking the pot while a
  buy one second earlier does, its own fee waiting in the pot and reaching it seven days later;
  with a dead core, a buyer who qualifies after an earlier payout paid once their buy is seven
  days old and the earlier winner not paid again, and a game opened by dust only paying the
  first later qualifying buyer; such a late buy still counting for a later nap when the core
  proves alive); a reverting, codeless, paused or re-ABI'd core with sells and buys still
  working and claims reverting with `CoreUnreadable` (and, for a core whose pages stop decoding
  while its frontier reads, the failsafe recording that and paying a week later); a winner
  contract that rejects ETH and
  later withdraws; a winner wallet that answers the payout with a gas-sized revert or return
  payload (the EIP-7702 return bomb) at 30M gas, credited and not blocking the next nap or the
  failsafe, then collecting through `withdrawOwed`; the payout gas bound (an ordinary wallet gets
  the whole stipend and never more, a wallet that needs 150k gas is credited); a re-entrant
  winner; and a fuzzed ETH accounting run (pot = fees in − payouts) over mixed buys,
  exact-output buys and sells.
- `test/HamsterNap3D.claims.t.sol`: a fresh PoolManager whose pool was seeded with tokens only:
  the first buy's fee becomes an ERC-6909 claim, later fees come as ETH, claims are redeemed by
  anyone, by a nap payout and by the failsafe.
- `test/HamsterNap3D.sworn.t.sol`: the mainnet-only Sworn check, read live, skipped on Sepolia,
  lifted after the first nap; sells always work.
- `test/HamsterNap3D.sepolia.t.sol`: the game replayed over real round pages captured from the
  live core (`test/fixtures/SepoliaRounds.sol`, rounds 483–642): the three real naps at 503, 519
  and 540 are found and paid in order, the single zero-work rounds 498 and 640 are not naps, the
  mock reproduces the captured pages and the documented error cases.
- `test/NapToken.t.sol`: supply, decimals, a transfer, no mint.
- `test/HamsterNap3D.core.t.sol`: owner authorization (including factory and origin rejection),
  literal construction without dependency code, zero-owner rejection, irreversible finalization,
  backlog settlement, broken/malformed/codeless/gas-burning/oversized core reads, atomic failures,
  independent configuration and state failures, timing changes, pot/debt/claim/history carryover,
  buys before a switch winning, exact timestamp boundaries, repeated migrations, seven-day clock
  restart, unchanged sells and LP collection, and owner reentrancy during payout. The migration
  winner fuzz test runs 512 cases over round lengths, frontiers and buy sizes.
- `test/HamsterNap3D.independent.t.sol` and `test/HamsterNap3D.invariant.t.sol` retain the previous
  contributor's adversarial regression tests and both 256-run, 96-call accounting campaigns.
  Renaming and updating their default timeline does not constitute an independent review of
  this change. The new hook and manifest still need their separate review assignments.
- `test/HamsterNap3D.fork.t.sol` retains five archival tests at Sepolia block 12030457. It skips
  offline. To opt in, supply an archive endpoint using Foundry's `--fork-url` and
  `--fork-block-number 12030457` flags with `--match-contract HamsterNap3DForkTest`. Tests read no
  environment variables. This historical fork does not validate the replacement proxy.

`test/mocks/MockSqueekCore.sol` models sparse pages, configurable timing/frontiers, pause status
and independently failing reads. Integration tests deploy a real local Uniswap v4 PoolManager;
no network is needed for the regular suite. Current-proxy live validation remains an operational
check for review/deployment, not a claimed result here.

The supplied protected floor checks are exercised separately in `test/scratch/` against built
creation code; scratch files are not part of the delivered project. See
`docs/CORE_MIGRATION.md` for the final validation record and review handoff.

## Build

```
forge build
FOUNDRY_FUZZ_SEED=0x78af848289a6cfdfe3ce352b08b7f4d056e64612920bbac37985ea48ca384cc2 forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, `bytecode_hash = "none"`,
`optimizer_runs = 44444444`, `via_ir = false`; no `ffi`, no `fs_permissions`. Dependencies are
vendored as plain files under `lib/` (no submodules): Uniswap v4-core `src/`, forge-std `src/`,
OpenZeppelin Contracts v5.4.0 `contracts/` (mocks removed), and solmate's `Owned.sol`, which
v4-core's `ProtocolFees` imports. v4-periphery is not used.

## Assumptions and choices

- The buyer is `tx.origin`, as the brief specifies. A smart-wallet or relayed buy records the
  relaying EOA. Using `tx.origin` is a known pattern to avoid for authorization; here it only
  decides who the latest buyer is and was a stated requirement.
- Without an earlier core switch, the game starts at the first swap of either direction; its
  round is where the scan begins. A nap already in progress counts as beginning there and has
  no earlier winner. A core switch explicitly resets the scan to the next round after that
  core's frontier, with an empty zero-work run, even before the first swap.
- A nap is a maximal run of zero-work rounds; one payout per run. A settled round missing from a
  page is zero work, per the docs. Rounds past the frontier are unknown and are not scanned.
- Exact-output buys pay a fee equal to 2% of the gross (net × 200 / 9800), so both buy kinds pay
  the same rate on what the buyer spends.
- v4 lets a hook change the specified side of a swap only in `beforeSwap`, before the fill is
  known, so an exact-input buy's 2% is reserved on the offered input and reconciled in
  `afterSwap` against the pool's real fill. The unused reservation is refunded as a credit in
  `owed`, not pushed during the swap: a push to the router would be lost by most routers, a push
  to the wallet could fail or re-enter, and a credit never blocks the swap. The buyer settles the
  full reservation with the PoolManager and pulls the difference with `withdrawOwed()`. The
  website should show a wallet's `owed` balance next to the buy panel.
- The failsafe is callable by anyone but pays only the last qualifying buyer before its cutoff.
  "Not advanced for 7 days" is dated from the hook's last sighting of an advance
  (`frontierSeenAt`), or from the frontier round's end if later. The sighting is an upper bound
  on when the core really settled that round, so the failsafe can open late but never early.
  Between interactions the hook sees nothing, so a core that advanced while nobody traded is
  noticed, and the clock restarted, by the very call that tries the failsafe. The brief's rule 5
  says only "the last qualifying buyer can take the pot"; reading it as the last buyer *before
  the cutoff* (the opening, or seven days ago if later) rather than at the moment of the call is
  our choice: the alternative made the failsafe a race that any 0.001 ETH buy in front of the
  real buyer's transaction would win. The cutoff rolls with time rather than staying at the
  first opening so that, with a core that never returns, a buyer who qualifies later is still
  the one paid for the fees through their buy, once it is seven days old: a cutoff frozen at
  the opening paid every later fee to the first winner, or locked them when nobody had
  qualified before the opening. The failsafe therefore pays the fees through the winner's last
  buy before the cutoff, not the whole pot; later fees wait for their own seven days.
- The failsafe pays what certified naps leave, never a certified nap's own pot: a nap the core
  certified before stalling (its three rounds inside `lastSeenFrontier`) belongs to the last
  buyer before it under rule 4, whoever bought later. Beyond 8 unscanned pages the failsafe
  asks for `settleNaps` first instead of scanning without bound in one transaction; that revert
  is always recoverable, because `settleNaps` works through any readable backlog whether or not
  `state()` still answers.
- "Stale" has two clocks, because a core can fail in two ways the hook cannot tell apart from
  the outside. The frontier clock covers a core that stops reporting progress. The page clock
  covers a core that keeps reporting progress nobody can verify (a `roundPage` upgrade, a page
  that no longer decodes, a core certifying nothing from the scan position): without it the pot
  could never be paid after `finalizeCore`. The page clock starts only from a persisted sighting
  of that state by a `failsafe()` call, never retroactively from an old scan, so a backlog that
  simply went unclaimed for a week does not open the failsafe the moment a page hiccups: the
  first call records the failure, and the payout needs the page still unreadable seven days
  later. The failsafe's own scan reads pages, so a healthy core always shuts it again.
- A frontier the core reports for a round that has not ended is ignored rather than clamped to
  the last ended round: a clamp would move with the clock and count as a fresh advance on every
  read, which is exactly what a misreporting core must not be able to do to the failsafe.
- The hook accepts ETH only from the PoolManager, so stray transfers cannot muddle the pot.
- Payouts give the winner's wallet 100,000 gas, copy no return data, run under a reentrancy
  lock with state updated before the call, and credit a failing payout instead of retrying it.
  Forwarding all gas and copying the return data (what a plain `call{value}` does) let a
  winner's EIP-7702 code answer with a payload the hook could not afford to copy, freezing every
  later nap behind it; the bounded, copy-free call cannot be made to fail from the callee's side.
- The partial-fill refund of an exact-input buy (rule 1) is credited to `tx.origin`, the brief's
  buyer, not to the router or smart account that settled the ETH with the PoolManager. v4 lets
  `afterSwap` return value only in the unspecified currency (NAP on a buy), so the unused ETH
  reservation cannot be handed back inside the swap; crediting the router would strand it in
  most routers. For a relayed or ERC-4337 buy the relaying EOA therefore holds the credit, as it
  holds the latest-buyer position; the amount is at most 2% of the unfilled input. Buyers who
  trade through a relayer should use exact-output orders or a limit that fills.
- Both fee formulas round down: a buy below 50 wei pays no fee and is not recorded, and every
  buy underpays by less than 1 wei. The leak is sub-wei per swap and a sub-50-wei buy cannot
  qualify, so this is intended, not corrected.
- The Sworn check reverts a buy when the registry call fails on mainnet; sells are unaffected.
  On Sepolia, this launch, the check never runs.

## Operational responsibilities

- **Owner.** The launch owner alone chooses and finalizes the core. There is no backend, signer
  or required keeper. All game maintenance remains permissionless: `settleNaps(maxPages)` when
  a nap has settled, `redeemClaims()` if claims sit idle, `failsafe()` after seven stale days.
  The site may expose game actions; owner configuration is an operational responsibility.
- **Gas for claims.** A page costs one `roundPage` call of up to 16 records; `settleNaps(10)`
  covers about a day. After a long idle stretch call it repeatedly; progress is kept.
- **Winner that cannot receive ETH.** A contract wallet without a payable fallback, or one whose
  receive needs more than 100,000 gas, is credited in `owed` and must call `withdrawOwed()`
  itself. The website should show a wallet's `owed` balance with a withdraw button.
- **Failsafe with a backlog.** If `failsafe()` reverts with `NapsUnsettled`, call
  `settleNaps(maxPages)` until `scanRound` passes `lastSeenFrontier`, then call it again. The
  website's Claim button covers the first step; `failsafeWinner()` shows who the failsafe pays.
  This works even when `state()` no longer answers: the scan then runs through the last
  frontier the hook saw.
- **Failsafe when the core reports progress nobody can read.** If `settleNaps` reverts with
  `CoreUnreadable` while buys keep seeing the frontier advance (`FrontierSeen` events), call
  `failsafe()` once: it records the failure (`PageFailureSeen`, `pageFailureSeenAt`) and
  `failsafeOpensAt()` moves to seven days later. Call it again then. If the pages come back in
  the meantime, `settleNaps` clears the record and pays the naps instead; do that before the
  owner considers a switch.
- **Failsafe after the core is gone for good.** Buys keep working and keep paying fees. Call
  `failsafe()` again whenever `failsafeWinner()` shows an amount: seven days after the latest
  buy, the fees since the previous payout go to the buyer who was last when they were paid.
  `NothingToPay` means the fees in the pot are not seven days old yet.
- **Partial-fill refunds.** A buyer whose exact-input buy stopped at a price limit has the unused
  fee reservation in `owed` and pulls it with `withdrawOwed()`; it never expires.
- **Dependency risk.** If SqueekCore pauses or breaks, buys and sells keep working, claims revert
  until it returns, and the failsafe opens after seven days. If it is upgraded with a different
  read ABI, claims revert and the failsafe is the way out unless the owner migrates before
  finalization: with `state()` broken the scan still finishes the rounds the hook saw certified
  through `roundPage`; with `roundPage` broken the page clock opens the failsafe seven days
  after a `failsafe()` call records it. A switch restarts the clock. Review external proxy
  upgrades separately.
- **Security.** Tests passing are not an audit. The brief asks for an independent adversarial
  review of the hook and its tests before release; this stage delivers the code and tests only.

## After launch

- **Core selection:** the initial proxy and timing are already configured from the approved
  literals. If SqueekChain changes its proxy, the owner obtains the replacement address from
  SqueekChain's operator and corroborates its `configuration()`, `state()` and `roundPage()` on
  Sepolia. Verify that it follows the API and the intended hamster; ABI validity is insufficient.
  Call `settleNaps(maxPages)` repeatedly until caught up, then call `setCore(newCore)` from the
  owner wallet. If the next read is unavailable, explicitly accept that its unscanned history is
  dropped. Confirm `CoreChanged`, `core()`, cached timing, the new scan and failsafe opening.
- **Finalization:** after verifying the operator's final core, the owner calls `finalizeCore()`.
  Confirm `coreFinalized() == true` and `CoreFinalized`. This cannot be undone; no new owner can
  be appointed, and a later operator proxy migration will require the game's failsafe or a
  separate deployment. No deadline or automatic finalization is added.
- **Deployment services:** prepare and independently review a fresh manifest for `NapToken` and
  `HamsterNap3D` with constructor arguments in the order above, mine flags `0x20cc`, and perform
  source publication, attestation, admission and deployment. Keep policy and signed-artifact
  linkage in those services. No broadcast or existing deployment-address reuse is part of this
  implementation assignment.
- **Site integration:** use the new hook ABI and actual deployed addresses after launch; read
  `core()`, `coreFinalized()` and `owner()`, and show past `CoreChanged` events. Nap round ids may
  repeat across core changes: associate events with their active core using log ordering rather
  than treating `napStart` alone as a globally unique id. Historic buy rounds are never rewritten.

## Changes in the review revisions

The third review (of the core-replacement version) reopened it with three reproducible
liveness defects and one advisory, answered in `.imd-responses.json` and fixed here with
regression tests in `test/HamsterNap3D.recovery.t.sol`; the reviewer's three proofs pass:

- `settleNaps` and `setCore`'s old-core check gave up as soon as `state()` was unreadable, though
  the hook had seen the frontier and `roundPage` still answered: a backlog of more than eight
  pages could then never be paid (the failsafe refused it with `NapsUnsettled`, the only way
  through was the reverting `settleNaps`), and `setCore` dropped naps it had seen certified.
  Both now fall back to `lastSeenFrontier` (rule 5, replacement step 1 and 2).
- A core whose `state()` kept advancing while `roundPage` was unreadable froze the pot for good
  after `finalizeCore`: every failsafe call restarted the frontier clock. The page clock
  (rule 7, `pageFailureSeenAt`, `PageFailureSeen`) opens the failsafe seven days after a
  `failsafe()` call records that state.
- A reported frontier for a round that has not ended was recorded and dated the failsafe from
  that round's end, so one misreport pushed it out by years. Such a frontier is now ignored
  (rule 7), and `setCore` refuses a replacement whose genesis or frontier round is still ahead
  of the clock (`InvalidGenesis`, `InvalidCoreFrontier`), so a switch cannot do the same.
- Advisory, on the owner's power over the core: the timeline checks above close the "failsafe a
  century out, then finalize" avenue; the ability to pick the core, and so the winners, is the
  brief's and stays, now stated plainly under the trust assumption.

The second review reopened the revised version with one reproducible defect, fixed here with
regression tests (`.imd-responses.json` answers each finding):

- With a dead core the failsafe winner was frozen at the first opening: every later qualifying
  buyer's fee went to that first winner at every later `failsafe()` call, and when nobody had
  qualified before the opening every later fee was locked behind `NoQualifyingBuyer`. The
  failsafe's cutoff now rolls, max(opening, now − 7 days), and the failsafe pays the fees
  through the winner's last buy before it instead of the whole pot (rule 7, `failsafeCutoff()`).
  The anti-sniping property is kept: a buy in front of the failsafe call still wins nothing.

The first review reopened the first accepted version with two reproducible defects, both
fixed with regression tests:

- A winner's wallet answering the payout with a gas-sized payload made `settleNaps` and
  `failsafe` run out of memory gas at any gas limit, freezing every later nap. Payouts now use
  a bounded, copy-free call (`PAYOUT_GAS`), credit on failure, and the review's proof passes.
- `failsafe` paid the whole pot, a certified but unclaimed nap's share included, to whoever
  bought last. It now settles certified naps through `lastSeenFrontier` first (or asks for
  `settleNaps` beyond 8 pages, or proceeds when the core's pages cannot be read) and pays only
  what is left.
- Advisory, also changed: the failsafe winner is fixed at the moment the failsafe opened
  (`BuyRecord.time`, `failsafeWinner()`), closing a 0.001 ETH buy-and-call race for the pot.
  The second revision replaced that fixed moment with the rolling cutoff above, which keeps the
  race closed.
- Advisory, documented and kept: the partial-fill refund goes to `tx.origin`, and fees round
  down (see Assumptions).
