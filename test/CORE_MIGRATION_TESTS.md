# Independent core migration tests

This contribution tests `setCore` and `finalizeCore` against the approved workflow. It adds tests only; it does not change contracts, configuration, dependencies, ABI exports or deployment artifacts.

| File | Additional coverage |
| --- | --- |
| `HamsterNap3D.migration.t.sol` | Unauthorized senders with the owner as transaction origin, before and after finalization; a third zero-work round on the next page blocking migration; finalization with pending naps or an unreadable core; atomic rejection of malformed response lengths and out-of-range timing/frontier words; failed migration preserving an already-open failsafe; unreadable old state versus unreadable old pages; old winner debt surviving dropped rounds; skipped new-core history and cleared old zero runs; strict timestamp eligibility, dust and no duplicate payments across two migrations; frontier advancement restarting the new clock; ERC-6909 claims and partial-fill refunds carried independently of the pot. |
| `HamsterNap3D.migration.invariant.t.sol` | Two stateful campaigns: repeated migration, and migration mixed with irreversible finalization. Each uses 256 runs of 96 calls, with unexpected handler reverts treated as failures. Deterministic companion tests demonstrate blocked migration, successful replacement, invalid-candidate rejection, debt carryover and withdrawal, finalization refusal and repeated failsafe payouts. |
| `HamsterNap3D.migration.timeline.t.sol` | The replacement-timeline rules added in the latest revision: a future genesis reverts `InvalidGenesis` (genesis at the switch is accepted), a frontier whose round has not ended reverts `InvalidCoreFrontier` (one ending exactly at the switch is accepted, uint64 max refused), every accepted switch opens the failsafe exactly seven days later, and every refused switch leaves state unchanged. Also: an unreadable old `state()` falls back to the last seen frontier, so a seen nap blocks migration and stays payable; rounds the hook never saw, or history whose pages are also unreadable, drop; a switch clears a recorded page failure and restarts the clock; after `finalizeCore`, a core that advances its frontier with no readable pages cannot hold the failsafe shut beyond seven days from the record; a replacement core's unended frontier is ignored. |
| `independent/CoreMigrationHandler.sol` | Bounded random buys, sells, time advancement, append-only certification, independently failing core reads, valid/invalid migrations, unauthorized administration, settlement, receiver rejection, withdrawals, claim redemption and failsafe boundaries. |

The handler models the revised fallback. With `state()` unreadable, `settleNaps` scans through the last seen frontier and migration is blocked while that page answers. It also asserts that outage probes never record a page failure.

Six property tests each run 1,000 cases, configured inline in Solidity. They cover caller authorization, response lengths, high bits in uint64 fields, winner/fee eligibility across unrelated round schedules, future genesis, and ended versus unended frontiers.

The invariant model stores its own chronological purchases and sums individual fees. It determines awards using timestamps, independently of the hook's binary search and cumulative checkpoints. After each random action it checks every recorded buy, selected core and timing, scan progress, permanent finalization, the failsafe clock, latest buyer, nap count and awards. Winners' received ETH plus outstanding debt must equal their modeled awards. The hook's ETH plus its actual ERC-6909 balance must equal the remaining pot plus debt, and all fees must remain accounted for. Migrations cannot send value to the administrator.

The harness uses the existing repository mock core, the real local Uniswap v4 PoolManager, production hook and NAP token. The initial pool contains tokens only, forcing the first fee to be backed by an ERC-6909 claim. As in the existing fixture, the test router is prefunded and buyer identities are simulated; it is not a production router. Certification only appends closed rounds within each modeled core timeline. There are no RPC, FFI, new dependency or environment-mutation requirements.

Validation on Foundry 1.8.3 with `FOUNDRY_FUZZ_SEED=0x78af848289a6cfdfe3ce352b08b7f4d056e64612920bbac37985ea48ca384cc2`, against the revised hook (future-genesis and ended-frontier checks, last-seen-frontier fallback, page-failure clock):

- `forge build` passed.
- `forge test` passed: **188 passed, 0 failed, 1 skipped**. The skip is the existing optional archival fork suite, with no active fork.
- The migration suites account for **30 tests**, including **6,000 fuzz cases** and **49,152 random handler calls**. Both invariant campaigns reported zero unexpected reverts.
- Earlier fixtures used a replacement genesis one second in the future. The revised hook correctly refuses that, so they now warp one second and start the replacement timeline at the switch. Each assertion still checks the same property.

Build and cache output were directed into `test/scratch/` using `FOUNDRY_OUT` and `FOUNDRY_CACHE_PATH`. Those outputs are disposable and are not needed to reproduce the tests. To run just this contribution with the assignment seed:

```sh
FOUNDRY_FUZZ_SEED=0x78af848289a6cfdfe3ce352b08b7f4d056e64612920bbac37985ea48ca384cc2 forge test --match-path 'test/HamsterNap3D.migration*.t.sol'
```

No new contract defect was reproduced in this scope. These are offline migration and accounting checks; they do not establish the authenticity of an owner-selected core or validate the replacement proxy's live state. No new fork block was requested for this assignment, and no live fork run is claimed.
