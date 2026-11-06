# HamsterNap3D contract handoff

This contribution implements the contract changes in the approved Hamster Nap 3D workflow.
It supplies source, tests and ABI exports. It does not supply a replacement launch manifest,
an independent audit, deployment addresses, or a website release. Existing manifest/site
artifacts describe an earlier deployment and must be replaced by their assigned contributors.

## Deployment inputs

| Item | Value / source |
| --- | --- |
| Chain | Ethereum Sepolia, 11155111 |
| Token | `src/NapToken.sol:NapToken`, no constructor arguments |
| Token metadata | Hamster Nap 3D / NAP, 18 decimals |
| Supply | 10^27 minor units, minted once to the deploying factory |
| Hook | `src/HamsterNap3D.sol:HamsterNap3D` |
| Hook constructor, in order | `IPoolManager poolManager_`, `address factory_`, `address owner_` |
| Manifest substitutions | `$poolManager`, `$factory`, `$owner`, in that order |
| Owner | The launch owner; never the deployment caller or transaction origin |
| Initial core | `0xFD6C166D4B8E2962E65746a13e5a0797CD4dE0c4` |
| Initial genesis / round duration | 1793735400 / 600 seconds, literals supplied by the approved workflow |
| Pool | Native ETH / NAP, LP fee 12500, tick spacing 60 |
| Hook address flags | 8396 (`0x20cc`), mine a fresh CREATE2 salt for the new creation code and arguments |
| Opening price | Derived by the deployment service under the launch policy |

The hook constructor does not call any dependency. The owner must be nonzero and is immutable.
There is no third deployed helper, externally linked library, ownership transfer, renunciation,
pause, upgrade, fee setting or administrative withdrawal. The token retains its standard fixed
supply and transfer behavior; only its display name changed.

## ABI changes

The authoritative exports are [HamsterNap3D.json](abi/HamsterNap3D.json) and
[NapToken.json](abi/NapToken.json), generated with `forge inspect <Contract> abi --json`.

| Surface | Meaning |
| --- | --- |
| `core() -> address` | Current SqueekCore proxy; replaces the old `CORE()` constant getter |
| `owner() -> address` | Fixed constructor-supplied launch owner |
| `coreFinalized() -> bool` | Whether replacement is permanently disabled |
| `setCore(address)` | Owner-only, reversible selection until finalized; Solidity uses the `ISqueekCore` interface type |
| `finalizeCore()` | Owner-only, permanent; a repeated call reverts |
| `CoreChanged(address indexed oldCore, address indexed newCore)` | Successful replacement / same-address refresh |
| `CoreFinalized(address indexed core)` | The selected address is now fixed by this hook |
| `GENESIS_TIMESTAMP()`, `ROUND_DURATION()` | Existing getter names, now storage reads |
| `roundAt`, `roundStart`, `roundEnd` | Now `view`, using the cached current-core timing |
| `CORE_READ_GAS()` | Fixed per-read budget of 5,000,000 gas |
| `pageFailureSeenAt() -> uint256` | When `failsafe()` first found the frontier readable but the next page unreadable; 0 while none stands |
| `PageFailureSeen(uint64 scanRound, uint64 frontier, uint256 failsafeOpensAt)` | That record, emitted by the non-reverting `failsafe()` call that made it |

New errors: `NotOwner`, `InvalidOwner`, `CoreIsFinalized`, `InvalidRoundDuration`,
`InvalidCoreFrontier`, `InvalidGenesis`, and `InsufficientCoreReadGas`. Migration also uses the existing `CoreUnreadable`, `NapsUnsettled`
and `Reentrancy` errors. No data is returned by either administrator call.

`BuyRecord` retains its original shape. Its `round` is historical, while its `time` orders all
buys across migrations. Both the nap payout and `winnerBefore` use the current core's
`roundStart(napStart)` as a strict timestamp cutoff. `NapSettled` retains its original event
shape; indexers must associate it with the active core using `CoreChanged` log order because
round ids can repeat on another core.

## Migration state and failure behavior

A switch leaves fee accounting, the pot, latest buyer, every buy, ERC-6909 claims, refund and
winner debts, nap count, and first-game state intact. It replaces the core and cached timing,
sets the scan to `newFrontier + 1`, clears the zero-work run and any recorded page failure, and
dates the frontier observation at the switch. The failsafe cannot open before seven days after
that observation, and the new frontier's round has ended by then (see below), so the switch is
the date.

Once the scan has started, readable old-core history must be processed with `settleNaps`; this conservatively
includes pending worked rounds. The switch probes the next pending page and refuses while
that page can make progress. The frontier that bounds the probe is the one old `state()`
reports now or, if that cannot be read, the last credible frontier the hook saw
(`lastSeenFrontier`): a broken `state()` alone never drops a nap the hook saw certified while
`roundPage` still answers. If a later page is unreadable, the readable prefix must first be
settled using smaller page batches. Only when the next required page is unreadable (or
certifies nothing) is the remaining old history dropped, as requested. Failure of the old
configuration alone does not bypass settlement, since its timing is already cached.

The new configuration and frontier must be readable, and the new timeline must already be
running: a genesis after the current block reverts `InvalidGenesis`, and a frontier whose
round has not ended yet in the new timing (genesis + frontier × duration after the current
block) reverts `InvalidCoreFrontier`, as does a frontier of uint64 max. No honest core has
settled a round that is not over, and a future timeline would postpone the failsafe (with a
genesis a century ahead, by a century). The boundary second, genesis + frontier × duration
equal to the block timestamp, is accepted. A zero duration, fields outside uint64 and invalid
response sizes are rejected. A failed switch rolls back completely. The new core's page history
is not imported or paid; the first scanned round is strictly after its supplied frontier.
Choosing the same address is permitted before finalization and uses the same validation and
reset rules.

Outside migration, two further rules protect the failsafe from a core that half works. A
frontier `state()` reports for a round that has not ended (at or past the running round) is
ignored, never clamped, so a misreporting core cannot keep the failsafe shut or push it out. And
a `failsafe()` call that finds the clock shut, `state()` readable and the next unscanned page
unreadable records the moment (`pageFailureSeenAt`, `PageFailureSeen`) and returns; the
failsafe then opens seven days later unless a scan reads a page first, so a core that keeps
reporting progress nobody can verify cannot freeze the pot after finalization.

Core reads use static calls, bounded gas and bounded return-data copying. The caps are 256 bytes
for state, 352 for configuration and 2,880 for a page with 16 five-word checkpoints. These bounds
come from `ISqueekCore`, not a new dependency ABI. A gas-exhausting or oversized answer counts as
unreadable instead of exhausting the hook while it tries to recover. The relevant fields are
validated; unused configuration/state fields do not establish authenticity of a core.

Before each old-core migration probe, the hook requires 5,089,365 gas of headroom: the read
budget plus EIP-150 allowance and 10,000 gas for call/encoding overhead. Too little caller gas
reverts `InsufficientCoreReadGas` rather than classifying the core as unreadable. This closes
a reproduced case where a caller could deliberately starve a readable old core and bypass its
pending nap. Tests cover starving both state and a page after an expensive state read, as well
as successful recovery from a core that consumes the entire genuine read budget. Use normal
gas estimation for `setCore`; this reserve is not additional gas spent, and swaps have no such
minimum-gas requirement.

Both admin entry points share the existing settlement/withdrawal reentrancy lock. An owner
receiving a nap payout cannot switch cores while the scan is still in progress. Finalization
changes neither scan state nor funds and does not restart the failsafe clock. Sells execute
without any core read; LP removal and zero-liquidity fee collection still have no hook callback.
The existing 2% buy fee, partial-fill refund, native-claim fallback and payout behavior remain.

## Owner trust and independent review

The first review question is the owner's influence over the source of truth. Before finalization,
its key can select a dishonest core with a plausible ABI, choose a different timeline that makes
a recorded buy of its own the winner, discard unreadable rounds, or restart the failsafe's seven
days with each switch. That can affect winners and liveness. There is no owner withdrawal or
direct fee share, but core selection is still economically powerful. The requirements
explicitly authorize this power; this implementation does not add a timelock, core allowlist or
automatic finalization. It does refuse a replacement whose timeline is ahead of the clock, so a
switch delays the failsafe by at most seven days and finalization cannot lock in a failsafe
that never opens.

Finalization fixes only this hook's pointer and cached timing. It cannot freeze SqueekChain's
proxy upgrades or reporting. Its operator remains trusted to return authentic, coherent settled
rounds. The owner's operational obligation is to verify the real operator's proxy, timing and
ledger before switching, then finalize only after the operator's core is final. The exact
post-launch procedure is in the README's **After launch** section.

An independent contributor must review the accepted source and separately generated manifest.
Suggested areas are the above owner trust, readable-prefix settlement, timestamp eligibility
across changing timelines, atomic failures, payout reentrancy, bounded dependency reads, the
new constructor arguments, and CREATE2 permissions. Policy, publication, attestation and
signed-artifact linkage belong to deployment services; concrete constructor/source/policy or
authorization conflicts remain review findings. This implementation note is not that review.

## Local validation

With the unchanged Foundry configuration (Solidity 0.8.26, Cancun, optimizer 44,444,444 runs,
no via-IR), these checks passed:

- `forge build`.
- `FOUNDRY_FUZZ_SEED=0x78af848289a6cfdfe3ce352b08b7f4d056e64612920bbac37985ea48ca384cc2 forge test --summary`:
  **148 passed, 0 failed, 1 skipped**. The skip is the archival fork suite's setup with no active
  fork. The 42 new tests are in `test/HamsterNap3D.core.t.sol`, including 512 migration fuzz cases.
  The original suites remain green, including both 256-run × 96-call invariant campaigns.
- `forge fmt --check`.
- All **16** supplied protected checks, copied unmodified into scratch and run against built
  creation code with an isolated local manager/factory/owner. This includes the three own-token
  checks as an additional standard-token compatibility check. No scratch scaffold is delivered.
- Generated ABI exports match the compiler output. Runtime size is **19,978 bytes** for
  HamsterNap3D and **2,291 bytes** for NapToken, both below EIP-170; no library link placeholders.

No fork against the replacement proxy, Slither run, independent review, network transaction or
publication is claimed. The regular suite has no network or environment-variable dependency.
The retained optional historical replay can be invoked with an archive fork at block 12030457;
it uses a test-only hook initialized to the old literals, never modifies the external proxy,
and does not validate this launch's new core. Tests are evidence of local behavior, not
independent approval or deployment readiness.
