// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {HamsterNap3D} from "src/HamsterNap3D.sol";
import {Swapper} from "../mocks/Swapper.sol";
import {RejectingWinner} from "../mocks/RejectingWinner.sol";
import {SequenceCore} from "./SequenceCore.sol";

/// @dev Independent linear history model. It never derives expected fees or awards from hook counters.
contract NapSequenceHandler is Test {
    using PoolIdLibrary for PoolKey;

    struct Purchase {
        uint64 round;
        uint256 time;
        uint256 fee;
        address qualifyingBuyer;
    }

    HamsterNap3D public immutable hook;
    SequenceCore public immutable core;
    Swapper public immutable router;
    RejectingWinner public immutable rejecting;
    PoolKey private key;
    address[4] public actors;
    Purchase[] private history;

    uint256 public fees;
    uint256 public allocated;
    mapping(address => uint256) public awards;
    /// @dev Unused exact-input fee reservations of partial fills, owed back to the buyer.
    mapping(address => uint256) public refunds;
    uint256 public totalRefunds;
    address public latest;
    uint64 public cursor;
    uint64 public zeros;
    uint64 public napStart;
    uint256 public naps;
    /// @dev The highest frontier a successful hook call has read, and when. The hook cannot know
    /// when the core really advanced, so the failsafe's seven days run from the hook's sighting.
    uint64 public observedFrontier;
    uint256 public observedAt;
    uint256 public buys;
    uint256 public sells;
    uint256 public claims;
    uint256 public failsafes;
    uint256 public withdrawals;
    uint256 public partialFills;
    uint256 public failsafeNaps;
    uint256 public unsettledRefusals;

    constructor(HamsterNap3D h, SequenceCore c, Swapper r, PoolKey memory k) {
        hook = h;
        core = c;
        router = r;
        key = k;
        rejecting = new RejectingWinner();
        actors = [makeAddr("sequence.alice"), makeAddr("sequence.bob"), makeAddr("sequence.carol"), address(rejecting)];
    }

    function buy(uint256 amountSeed, uint8 actorSeed, uint8 kind) external {
        address actor = actors[actorSeed % 4];
        uint256 amount = _amount(amountSeed, kind);
        vm.prank(actor, actor);
        BalanceDelta delta =
            kind % 2 == 0 ? router.swap(key, true, amount) : router.swapExact(key, true, int256(amount));
        uint256 gross = uint256(uint128(-delta.amount0()));
        assertGt(delta.amount1(), 0, "funded swaps must deliver tokens");
        if (kind % 2 == 0) assertEq(gross, amount, "this campaign has enough liquidity for full fills");
        else assertEq(uint256(uint128(delta.amount1())), amount);
        _start();
        _record(actor, gross, gross / 50);
    }

    /// @notice A buy bounded by a sqrt price 1e-12 to 1e-6 below the current one, so the pool often fills
    /// only part of it. The fee and the 0.001 ETH threshold must follow the ETH really spent.
    function buyLimited(uint256 amountSeed, uint8 actorSeed, uint32 limitSeed, bool exactOutput) external {
        address actor = actors[actorSeed % 4];
        uint256 amount = bound(amountSeed, 50, exactOutput ? 1000 ether : 10 ether);
        (uint160 price,,,) = StateLibrary.getSlot0(router.manager(), key.toId());
        uint160 limit = uint160(uint256(price) - uint256(price) * bound(limitSeed, 1, 1e6) / 1e12);
        uint256 owedBefore = hook.owed(actor);
        vm.prank(actor, actor);
        BalanceDelta delta = router.swapWithLimit(key, true, exactOutput ? int256(amount) : -int256(amount), limit);
        uint256 debit = uint256(uint128(-delta.amount0()));
        _start();
        if (exactOutput) {
            assertLe(uint256(uint128(delta.amount1())), amount);
            // The buyer pays the pool's ETH plus 2% of the total: debit / 50 is exactly the fee.
            _record(actor, debit, debit / 50);
        } else {
            assertLe(debit, amount, "never charged above the offered input");
            uint256 reserved = amount / 50;
            if (debit == amount) {
                _record(actor, amount, reserved);
            } else {
                // The router settled the pool's fill plus the whole reservation.
                uint256 poolEth = debit - reserved;
                uint256 due = poolEth * 200 / 9800;
                if (due > reserved) due = reserved;
                uint256 refund = reserved - due;
                assertEq(hook.owed(actor), owedBefore + refund, "unused reservation credited to the buyer");
                refunds[actor] += refund;
                totalRefunds += refund;
                _record(actor, poolEth + due, due);
                partialFills++;
            }
        }
    }

    function sell(uint96 amountSeed, uint8 actorSeed, bool exactOutput) external {
        uint256 amount = bound(amountSeed, 100, 0.001 ether);
        address actor = actors[actorSeed % 4];
        vm.prank(actor, actor);
        BalanceDelta delta =
            exactOutput ? router.swapExact(key, false, int256(amount)) : router.swap(key, false, amount);
        assertGt(delta.amount0(), 0);
        _start();
        sells++;
        // Sells never read the core, so they never move the failsafe's clock.
    }

    function advanceAndCertify(uint16 secondsSeed, uint8 countSeed, uint16 workBits) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 3600));
        uint64 available = _round() - 1 - core.frontier();
        if (available > 16) available = 16;
        uint64 count = uint64(bound(countSeed, 0, available));
        if (count > 0) core.certify(count, workBits);
    }

    function coreStatus(uint8 status) external {
        core.setStatus(status % 3 == 1, status % 3 == 2);
    }

    function settle(uint8 pagesSeed) external {
        uint256 pages = bound(pagesSeed, 1, 3);
        if (cursor == 0) {
            vm.expectRevert(HamsterNap3D.GameNotStarted.selector);
            hook.settleNaps(pages);
            return;
        }
        if (core.unavailable()) {
            vm.expectRevert(HamsterNap3D.CoreUnreadable.selector);
            hook.settleNaps(pages);
            return;
        }
        uint256 oldNaps = naps;
        _scanThrough(cursor + uint64(pages * 16) - 1);
        assertEq(hook.settleNaps(pages), naps - oldNaps, "independent nap count");
        _observe();
        claims++;
    }

    function redeem() external {
        hook.redeemClaims();
    }

    function receiverStatus(bool accept) external {
        rejecting.setAccepting(accept);
    }

    function withdraw(uint8 actorSeed) external {
        address actor = actors[actorSeed % 4];
        uint256 debt = hook.owed(actor);
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

    function takeFailsafeAfterSevenUnchangedDays() external {
        _failsafe(0);
    }

    /// @notice The failsafe called up to ten days after it opened, so the rolling cutoff (the later of
    /// the opening and seven days ago) reaches buys made after the opening or after an earlier payout.
    function takeFailsafeAfterExtraWait(uint32 extraSeed) external {
        _failsafe(bound(extraSeed, 0, 10 days));
    }

    function _failsafe(uint256 extra) private {
        // Seven days after the later of the last sighting and the sighted round's end. An advance
        // the hook has not seen yet must keep the failsafe shut, however old the advanced round is.
        uint256 since = 1793735400 + uint256(observedFrontier) * 600;
        if (observedAt > since) since = observedAt;
        uint256 at = since + 7 days;
        if (at > vm.getBlockTimestamp()) vm.warp(at);
        if (extra > 0) vm.warp(vm.getBlockTimestamp() + extra);
        bool unseenAdvance = !core.unavailable() && core.frontier() > observedFrontier;
        if (cursor == 0) {
            vm.expectRevert(HamsterNap3D.GameNotStarted.selector);
            hook.failsafe();
            return;
        }
        if (unseenAdvance) {
            vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, vm.getBlockTimestamp() + 7 days));
            hook.failsafe();
            return;
        }
        // A readable core: every certified nap is settled first, to its own winner, over at most eight
        // pages; a longer backlog refuses the failsafe and leaves the scan untouched.
        if (!core.unavailable() && cursor <= observedFrontier) {
            if (observedFrontier - cursor + 1 > 8 * 16) {
                vm.expectRevert(
                    abi.encodeWithSelector(HamsterNap3D.NapsUnsettled.selector, cursor + 8 * 16, observedFrontier)
                );
                hook.failsafe();
                unsettledRefusals++;
                return;
            }
        }
        // Rule 5 with the anti-sniping cutoff: the winner is the last qualifying buyer whose buy happened
        // strictly before the later of the opening and seven days ago, and it is owed the fees paid
        // through the last buy before that cutoff that no nap or earlier failsafe has paid yet.
        uint256 cutoff = vm.getBlockTimestamp() - 7 days;
        if (at > cutoff) cutoff = at;
        address winner;
        uint256 throughCutoff;
        for (uint256 i; i < history.length; i++) {
            if (history[i].time >= cutoff) break;
            throughCutoff += history[i].fee;
            if (history[i].qualifyingBuyer != address(0)) winner = history[i].qualifyingBuyer;
        }
        if (winner == address(0)) {
            vm.expectRevert(HamsterNap3D.NoQualifyingBuyer.selector);
            hook.failsafe();
            return;
        }
        // The pre-payment scan's naps are part of the same call: if it then reverts, they roll back too.
        uint256 napsBefore = naps;
        uint256 allocatedBefore = allocated;
        uint64 cursorBefore = cursor;
        uint64 zerosBefore = zeros;
        uint64 napStartBefore = napStart;
        uint256 count = history.length;
        uint256[] memory awardsBefore = new uint256[](actors.length);
        for (uint256 i; i < actors.length; i++) {
            awardsBefore[i] = awards[actors[i]];
        }
        if (!core.unavailable()) _scanThrough(observedFrontier);
        if (throughCutoff <= allocated) {
            naps = napsBefore;
            allocated = allocatedBefore;
            cursor = cursorBefore;
            zeros = zerosBefore;
            napStart = napStartBefore;
            for (uint256 i; i < actors.length; i++) {
                awards[actors[i]] = awardsBefore[i];
            }
            assertEq(history.length, count);
            vm.expectRevert(HamsterNap3D.NothingToPay.selector);
            hook.failsafe();
            return;
        }
        failsafeNaps += naps - napsBefore;
        awards[winner] += throughCutoff - allocated;
        allocated = throughCutoff;
        failsafes++;
        hook.failsafe();
    }

    function checkModel() external view {
        assertEq(hook.cumulativeFees(), fees, "fees computed from actual swap ETH");
        assertEq(hook.cumulativePaid(), allocated, "only eligible buys fund awards");
        assertEq(hook.pot(), fees - allocated);
        assertEq(hook.latestBuyer(), latest);
        assertEq(hook.scanRound(), cursor);
        assertEq(hook.napsSettled(), naps);
        assertEq(hook.firstNapSettled(), naps > 0);
        assertEq(hook.zeroRun(), zeros);
        uint256 totalDebt;
        uint256 paid;
        for (uint256 i; i < actors.length; i++) {
            uint256 debt = hook.owed(actors[i]);
            assertEq(
                actors[i].balance + debt, awards[actors[i]] + refunds[actors[i]], "wrong winner or duplicate payment"
            );
            totalDebt += debt;
            paid += actors[i].balance;
        }
        assertEq(hook.totalOwed(), totalDebt);
        assertEq(paid + totalDebt, allocated + totalRefunds);
        assertEq(
            address(hook).balance + hook.claimsHeld() + paid, fees + totalRefunds, "every fee wei is accounted for"
        );
        assertEq(hook.lastSeenFrontier(), observedFrontier, "frontier sightings");
        assertEq(hook.frontierSeenAt(), observedAt, "failsafe clock");
    }

    /// @dev Walks certified rounds from the cursor through `end` (capped at the frontier), round by round.
    function _scanThrough(uint64 end) private {
        if (end > core.frontier()) end = core.frontier();
        while (cursor <= end) {
            if (core.worked(cursor)) {
                zeros = 0;
            } else {
                if (zeros == 0) napStart = cursor;
                zeros++;
                if (zeros == 3) {
                    _allocateNap(napStart);
                    naps++;
                }
            }
            cursor++;
        }
    }

    function _allocateNap(uint64 start) private {
        // A linear sum over actual trade history is deliberately different from the hook's
        // binary search over cumulative checkpoints.
        uint256 eligible;
        address winner;
        for (uint256 i; i < history.length; i++) {
            Purchase memory p = history[i];
            if (p.round >= start) break;
            eligible += p.fee;
            if (p.qualifyingBuyer != address(0)) winner = p.qualifyingBuyer;
        }
        if (winner != address(0) && eligible > allocated) {
            awards[winner] += eligible - allocated;
            allocated = eligible;
        }
    }

    /// @dev A buy as the hook should see it: `gross` ETH really spent, `paidFee` of it to the pot.
    function _record(address actor, uint256 gross, uint256 paidFee) private {
        bool qualifies = gross >= 0.001 ether;
        if (qualifies) latest = actor;
        fees += paidFee;
        history.push(Purchase(_round(), vm.getBlockTimestamp(), paidFee, qualifies ? actor : address(0)));
        buys++;
        _observe(); // every buy reads the core
    }

    function _start() private {
        if (cursor == 0) {
            cursor = _round();
            observedAt = vm.getBlockTimestamp();
        }
    }

    function _observe() private {
        if (!core.unavailable() && core.frontier() > observedFrontier) {
            observedFrontier = core.frontier();
            observedAt = vm.getBlockTimestamp();
        }
    }

    function _round() private view returns (uint64) {
        return uint64((vm.getBlockTimestamp() - 1793735400) / 600 + 1);
    }

    function _amount(uint256 seed, uint8 kind) private pure returns (uint256) {
        uint256[6] memory edges = [uint256(49), 50, 51, 0.001 ether - 1, 0.001 ether, 0.001 ether + 1];
        if (kind % 3 == 0) return edges[seed % edges.length];
        return bound(seed, 100, 1 ether);
    }
}
