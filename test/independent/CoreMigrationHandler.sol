// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterNap3D} from "src/HamsterNap3D.sol";
import {MockSqueekCore} from "../mocks/MockSqueekCore.sol";
import {Swapper} from "../mocks/Swapper.sol";
import {RejectingWinner} from "../mocks/RejectingWinner.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice Independent migration oracle: timestamps and individual fees, never the hook's
/// buy checkpoints, determine awards. All trades use the real local PoolManager.
contract CoreMigrationHandler is Test {
    struct Purchase {
        uint64 round;
        uint64 time;
        uint256 fee;
        address latest;
    }

    HamsterNap3D public immutable hook;
    Swapper private immutable router;
    address private immutable administrator;
    PoolKey private key;
    MockSqueekCore public active;
    RejectingWinner public immutable rejecting;
    address[4] public actors;
    Purchase[] private purchases;
    uint256[4] public awards;

    uint64 public genesis;
    uint64 public duration;
    uint64 public cursor;
    uint64 public zeros;
    uint64 public zeroStart;
    uint64 public seen;
    uint256 public seenAt;
    uint256 public fees;
    uint256 public paid;
    uint256 public naps;
    address public latest;
    bool public finalized;
    uint256 public migrations;
    uint256 public blockedMigrations;
    uint256 public invalidCandidates;
    uint256 public finalizedRefusals;
    uint256 public unauthorizedRefusals;
    uint256 public failsafes;
    uint256 public withdrawals;

    constructor(HamsterNap3D hook_, Swapper router_, PoolKey memory key_, MockSqueekCore initial, address owner_) {
        hook = hook_;
        router = router_;
        key = key_;
        administrator = owner_;
        active = initial;
        genesis = initial.configuration().genesisTimestamp;
        duration = initial.configuration().roundDuration;
        cursor = initial.frontier() + 1;
        seen = initial.frontier();
        seenAt = vm.getBlockTimestamp();
        rejecting = new RejectingWinner();
        actors =
            [makeAddr("migration.alice"), makeAddr("migration.bob"), makeAddr("migration.carol"), address(rejecting)];
    }

    function buy(uint96 amountSeed, uint8 actorSeed, uint8 edge) external {
        uint256[6] memory amounts = [uint256(49), 50, 51, 0.001 ether - 1, 0.001 ether, 0.001 ether + 1];
        uint256 gross = edge % 2 == 0 ? bound(amountSeed, 100, 2 ether) : amounts[amountSeed % amounts.length];
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor, actor);
        BalanceDelta delta = router.swap(key, true, gross);
        assertEq(uint256(uint128(-delta.amount0())), gross, "campaign trades must be fully filled");
        uint256 charge = gross / 50;
        fees += charge;
        if (gross >= 0.001 ether) latest = actor;
        if (charge > 0 || gross >= 0.001 ether) {
            uint64 round =
                vm.getBlockTimestamp() < genesis ? 0 : uint64((vm.getBlockTimestamp() - genesis) / duration + 1);
            purchases.push(Purchase(round, uint64(vm.getBlockTimestamp()), charge, latest));
        }
        _observe();
    }

    function sell(uint64 amountSeed, uint8 actorSeed) external {
        vm.prank(actors[actorSeed % actors.length], actors[actorSeed % actors.length]);
        BalanceDelta delta = router.swap(key, false, bound(amountSeed, 1e10, 1e14));
        assertGt(delta.amount0(), 0, "sells survive every core status and finalization");
    }

    /// @dev Only closed rounds are certified, and the ledger is append-only within each epoch.
    function certify(uint16 elapsedSeed, uint8 countSeed, uint8 workBits) external {
        vm.warp(vm.getBlockTimestamp() + bound(elapsedSeed, 0, 7200));
        uint64 closed = vm.getBlockTimestamp() < genesis ? 0 : uint64((vm.getBlockTimestamp() - genesis) / duration);
        uint64 frontier = active.frontier();
        uint64 available = closed > frontier ? closed - frontier : 0;
        uint64 count = uint64(bound(countSeed, 0, available > 8 ? 8 : available));
        for (uint64 i; i < count; i++) {
            active.setWork(frontier + i + 1, workBits & (uint256(1) << i) == 0 ? 0 : 1);
        }
        active.setFrontier(frontier + count);
    }

    function coreStatus(uint8 status) external {
        status %= 5;
        active.setReverting(status == 4);
        active.setReadFailures(status == 1, status == 3, status == 2);
    }

    /// @dev A fresh mock gives each migration an unrelated round numbering and duration. Invalid
    /// candidates are tried even with a backlog, so error precedence and rollback are exercised.
    function migrate(uint16 durationSeed, uint8 frontierSeed, uint8 fault) external {
        MockSqueekCore candidate = new MockSqueekCore();
        uint64 nextDuration = uint64(bound(durationSeed, 1, 3600));
        uint64 nextFrontier = uint64(frontierSeed % 25);
        uint64 nextGenesis = uint64(vm.getBlockTimestamp() - uint256(nextFrontier) * nextDuration);
        candidate.setConfiguration(nextGenesis, nextDuration);
        candidate.setFrontier(nextFrontier);
        fault %= 4;
        if (fault == 1) candidate.setReadFailures(false, true, false);
        if (fault == 2) candidate.setReadFailures(true, false, false);
        if (fault == 3) candidate.setConfiguration(nextGenesis, 0);

        if (finalized) {
            vm.expectRevert(HamsterNap3D.CoreIsFinalized.selector);
            finalizedRefusals++;
        } else if (_readableBacklog()) {
            uint64 frontier = active.frontier() > seen ? active.frontier() : seen;
            vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.NapsUnsettled.selector, cursor, frontier));
            blockedMigrations++;
        } else if (fault != 0) {
            vm.expectRevert(
                fault == 3 ? HamsterNap3D.InvalidRoundDuration.selector : HamsterNap3D.CoreUnreadable.selector
            );
            invalidCandidates++;
        } else {
            active = candidate;
            genesis = nextGenesis;
            duration = nextDuration;
            cursor = nextFrontier + 1;
            zeros = 0;
            zeroStart = 0;
            seen = nextFrontier;
            seenAt = vm.getBlockTimestamp();
            migrations++;
        }
        vm.prank(administrator);
        hook.setCore(candidate);
    }

    function unauthorized(bool finalizeAttempt, uint8 actorSeed) external {
        vm.expectRevert(HamsterNap3D.NotOwner.selector);
        // The owner as origin does not authorize an intermediary as msg.sender.
        vm.prank(actors[actorSeed % actors.length], administrator);
        if (finalizeAttempt) hook.finalizeCore();
        else hook.setCore(active);
        unauthorizedRefusals++;
    }

    function finalize() external {
        if (finalized) vm.expectRevert(HamsterNap3D.CoreIsFinalized.selector);
        else finalized = true;
        vm.prank(administrator);
        hook.finalizeCore();
    }

    function settle(uint8 pagesSeed) external {
        uint256 pages = bound(pagesSeed, 1, 3);
        if (_stateUnavailable() || (cursor <= active.frontier() && _pageUnavailable())) {
            vm.expectRevert(HamsterNap3D.CoreUnreadable.selector);
            hook.settleNaps(pages);
            return;
        }
        uint256 beforeNaps = naps;
        _scan(pages * 16);
        _observe();
        assertEq(hook.settleNaps(pages), naps - beforeNaps, "independent nap count");
    }

    /// @dev Outages isolate the migrated failsafe clock from new observations. Boundary probes
    /// cover one second before, exactly at, and well after the independently calculated opening.
    function failsafeDuringOutage(uint8 when) external {
        active.setReverting(true);
        uint256 opening = _opening();
        uint256 at = when % 3 == 0 ? opening - 1 : when % 3 == 1 ? opening : opening + 8 days;
        if (at > vm.getBlockTimestamp()) vm.warp(at);
        if (vm.getBlockTimestamp() < opening) {
            vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, opening));
        } else {
            uint256 cutoff = vm.getBlockTimestamp() - 7 days;
            if (cutoff < opening) cutoff = opening;
            (address winner, uint256 eligible) = _before(cutoff);
            if (winner == address(0)) {
                vm.expectRevert(HamsterNap3D.NoQualifyingBuyer.selector);
            } else if (eligible <= paid) {
                vm.expectRevert(HamsterNap3D.NothingToPay.selector);
            } else {
                _allocate(winner, eligible);
                failsafes++;
            }
        }
        hook.failsafe();
    }

    function receiverStatus(bool accepting) external {
        rejecting.setAccepting(accepting);
    }

    function withdraw(uint8 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        // Debt comes from the model's awards minus ETH actually delivered, not owed().
        uint256 debt = awards[actorSeed % actors.length] - actor.balance;
        if (debt == 0) {
            vm.expectRevert(HamsterNap3D.NothingOwed.selector);
        } else if (actor == address(rejecting) && !rejecting.accepting()) {
            vm.expectRevert(HamsterNap3D.TransferFailed.selector);
        } else {
            withdrawals++;
        }
        vm.prank(actor);
        hook.withdrawOwed();
    }

    function redeem() external {
        hook.redeemClaims();
    }

    function checkModel() external view {
        assertEq(address(hook.core()), address(active), "selected core");
        assertEq(hook.GENESIS_TIMESTAMP(), genesis, "cached genesis");
        assertEq(hook.ROUND_DURATION(), duration, "cached duration");
        assertEq(hook.coreFinalized(), finalized, "finalization is permanent");
        assertEq(hook.owner(), administrator, "owner never changes");
        assertEq(hook.scanRound(), cursor, "epoch scan cursor");
        assertEq(hook.zeroRun(), zeros, "epoch zero run");
        assertEq(hook.zeroRunStart(), zeroStart, "epoch zero start");
        assertEq(hook.lastSeenFrontier(), seen, "epoch frontier");
        assertEq(hook.frontierSeenAt(), seenAt, "failsafe restart and observations");
        assertEq(hook.failsafeOpensAt(), _opening(), "independent failsafe clock");
        assertEq(hook.latestBuyer(), latest, "latest qualifying buyer survives migration");
        assertEq(hook.cumulativeFees(), fees, "sum of independently calculated fees");
        assertEq(hook.cumulativePaid(), paid, "only allocated fees are paid");
        assertEq(hook.pot(), fees - paid, "unallocated fees survive migration");
        assertEq(hook.napsSettled(), naps, "migration never settles or erases nap count");
        assertEq(hook.firstNapSettled(), naps > 0);
        assertEq(hook.buyCount(), purchases.length, "migration never drops buy records");
        uint256 cumulative;
        for (uint256 i; i < purchases.length; i++) {
            Purchase memory p = purchases[i];
            cumulative += p.fee;
            HamsterNap3D.BuyRecord memory actual = hook.buyAt(i);
            assertEq(actual.round, p.round, "historical rounds are preserved, not renumbered");
            assertEq(actual.time, p.time, "buy timestamp");
            assertEq(actual.cumulativeFees, cumulative, "buy fee checkpoint");
            assertEq(actual.latestBuyer, p.latest, "buy winner checkpoint");
        }
        uint256 debt;
        uint256 delivered;
        for (uint256 i; i < actors.length; i++) {
            assertEq(actors[i].balance + hook.owed(actors[i]), awards[i], "wrong winner, erased debt or double payout");
            debt += hook.owed(actors[i]);
            delivered += actors[i].balance;
        }
        assertEq(hook.totalOwed(), debt);
        assertEq(delivered + debt, paid);
        assertEq(address(hook).balance + hook.claimsHeld() + delivered, fees, "all fee value conserved");
        assertEq(administrator.balance, 0, "administration has no direct payout");
    }

    function _readableBacklog() private view returns (bool) {
        uint64 frontier = active.frontier() > seen ? active.frontier() : seen;
        return !_stateUnavailable() && !_pageUnavailable() && cursor <= frontier;
    }

    function _stateUnavailable() private view returns (bool) {
        return active.reverting() || active.stateReverting();
    }

    function _pageUnavailable() private view returns (bool) {
        return active.reverting() || active.pageReverting();
    }

    function _observe() private {
        if (!_stateUnavailable() && active.frontier() > seen) {
            seen = active.frontier();
            seenAt = vm.getBlockTimestamp();
        }
    }

    function _opening() private view returns (uint256) {
        uint256 end = uint256(genesis) + uint256(seen) * duration;
        return (seenAt > end ? seenAt : end) + 7 days;
    }

    function _scan(uint256 maxRounds) private {
        for (uint256 i; i < maxRounds && cursor <= active.frontier(); i++) {
            if (active.workOf(cursor) != 0) {
                zeros = 0;
            } else {
                if (zeros == 0) zeroStart = cursor;
                zeros++;
                if (zeros == 3) {
                    (address winner, uint256 eligible) = _before(uint256(genesis) + uint256(zeroStart - 1) * duration);
                    if (winner != address(0) && eligible > paid) _allocate(winner, eligible);
                    naps++;
                }
            }
            cursor++;
        }
    }

    function _before(uint256 cutoff) private view returns (address winner, uint256 eligible) {
        // Linear summation across every epoch, deliberately independent of the hook's binary search.
        for (uint256 i; i < purchases.length; i++) {
            if (purchases[i].time >= cutoff) break;
            eligible += purchases[i].fee;
            winner = purchases[i].latest;
        }
    }

    function _allocate(address winner, uint256 eligible) private {
        for (uint256 i; i < actors.length; i++) {
            if (actors[i] == winner) {
                awards[i] += eligible - paid;
                paid = eligible;
                return;
            }
        }
        revert("model winner is not an actor");
    }
}
