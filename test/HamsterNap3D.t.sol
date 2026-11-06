// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {HookTestBase} from "./HookTestBase.sol";
import {HamsterNap3D} from "../src/HamsterNap3D.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {BaseHook} from "../src/base/BaseHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {RejectingWinner} from "./mocks/RejectingWinner.sol";
import {ReturnBombWinner} from "./mocks/ReturnBombWinner.sol";
import {ISqueekCore} from "../src/interfaces/ISqueekCore.sol";

contract HamsterNap3DTest is HookTestBase {
    function setUp() public override {
        super.setUp();
        seedBothSides(1_000_000 ether);
        // The hamster worked every round up to and including the current frontier.
        workThrough(1, 649);
    }

    // ---------------------------------------------------------------- wiring

    function test_permissionsMatchAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeAddLiquidity);
        assertEq(HookFlags.fromPermissions(p), HOOK_FLAGS);
        assertEq(HookFlags.flagsOf(address(hook)), HOOK_FLAGS);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.factory(), factory);
        assertEq(Currency.unwrap(hook.token()), address(token));
        assertTrue(hook.poolBound());
    }

    function test_callbacksRefuseNonManager() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeInitialize(factory, key, SQRT_PRICE_1_1);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, 1), "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1 ether, 1), BalanceDelta.wrap(0), "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
    }

    function test_unlockCallbackRefusesNonManager() public {
        vm.expectRevert(HamsterNap3D.NotFromPoolManager.selector);
        hook.unlockCallback(abi.encode(uint256(1)));
    }

    function test_receiveRefusesStrangers() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_initializeRefusesNonFactory() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_initializeRefusesSecondPool() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.prank(factory);
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_initializeRefusesTokenPair() public {
        HamsterNap3D fresh = deployHook(manager, factory);
        MockERC20 a = new MockERC20("A", "A", 0);
        (address c0, address c1) =
            address(a) < address(token) ? (address(a), address(token)) : (address(token), address(a));
        PoolKey memory pair =
            PoolKey(Currency.wrap(c0), Currency.wrap(c1), POOL_FEE, TICK_SPACING, IHooks(address(fresh)));
        vm.prank(factory);
        vm.expectRevert();
        manager.initialize(pair, SQRT_PRICE_1_1);
        assertFalse(fresh.poolBound());
    }

    function test_initializeAcceptsListedFeeFromFactory() public {
        HamsterNap3D fresh = deployHook(manager, factory);
        PoolKey memory k = key;
        k.hooks = IHooks(address(fresh));
        vm.prank(factory);
        manager.initialize(k, SQRT_PRICE_1_1);
        assertTrue(fresh.poolBound());
        assertEq(PoolId.unwrap(fresh.poolId()), PoolId.unwrap(k.toId()));
    }

    // ---------------------------------------------------------------- fees and buyers

    function test_buyExactInputPaysTwoPercentAndBecomesLatestBuyer() public {
        uint256 before = address(swapper).balance;
        vm.expectEmit(true, false, false, true);
        emit HamsterNap3D.Buy(alice, 1 ether, 0.02 ether, 650, true);
        BalanceDelta delta = buy(alice, 1 ether);
        assertEq(delta.amount0(), -1 ether, "buyer pays exactly the input");
        assertGt(delta.amount1(), 0, "buyer receives tokens");
        assertEq(before - address(swapper).balance, 1 ether);
        assertEq(hook.pot(), 0.02 ether);
        assertEq(address(hook).balance, 0.02 ether, "fee settled as ETH");
        assertEq(hook.claimsHeld(), 0);
        assertEq(hook.latestBuyer(), alice);
        assertEq(hook.buyCount(), 1);
        assertEq(hook.scanRound(), 650, "game starts at the first swap's round");
        assertBacked();
    }

    function test_buyExactOutputPaysTwoPercentOfGross() public {
        BalanceDelta delta = buyExactOut(bob, 1000 ether);
        assertEq(delta.amount1(), 1000 ether, "exact token output");
        uint256 gross = uint256(uint128(-delta.amount0()));
        uint256 potAfter = hook.pot();
        // The fee is 2% of what the buyer spent, within rounding of a wei.
        assertApproxEqAbs(potAfter, gross * 200 / 10_000, 1);
        assertEq(address(hook).balance, potAfter);
        assertEq(hook.latestBuyer(), bob);
        assertBacked();
    }

    function test_sellPaysNoFeeAndKeepsLatestBuyer() public {
        buy(alice, 1 ether);
        uint256 potBefore = hook.pot();
        uint256 ethBefore = address(swapper).balance;
        BalanceDelta delta = sell(bob, 500 ether);
        assertGt(delta.amount0(), 0, "seller receives ETH");
        assertEq(address(swapper).balance - ethBefore, uint256(uint128(delta.amount0())));
        assertEq(hook.pot(), potBefore);
        assertEq(hook.latestBuyer(), alice);
        assertEq(hook.buyCount(), 1);
    }

    function test_dustBuyPaysFeeButDoesNotQualify() public {
        buy(alice, 1 ether);
        buy(bob, 0.0005 ether);
        assertEq(hook.pot(), fee(1 ether) + fee(0.0005 ether));
        assertEq(hook.latestBuyer(), alice);
        assertEq(hook.buyCount(), 2, "dust buys are recorded for the pot");
        assertEq(hook.buyAt(1).latestBuyer, alice);
    }

    function test_qualifyingThreshold() public {
        buy(alice, 0.001 ether - 1);
        assertEq(hook.latestBuyer(), address(0));
        buy(bob, 0.001 ether);
        assertEq(hook.latestBuyer(), bob);
    }

    function test_tinyBuyWithZeroFeeIsNotRecorded() public {
        buy(alice, 40);
        assertEq(hook.pot(), 0);
        assertEq(hook.buyCount(), 0);
    }

    function test_latestBuyerIsTheTransactionOrigin() public {
        // The router is msg.sender of the swap; the wallet is tx.origin.
        vm.prank(bob, alice);
        swapper.swap(key, true, 1 ether);
        assertEq(hook.latestBuyer(), alice);
    }

    // ---------------------------------------------------------------- partial fills

    /// @dev The fee and the threshold follow the ETH a buy really spent, not the input it offered.
    function test_partialDustFillDoesNotQualifyAndPaysFeeOnExecutedEth() public {
        buy(alice, 1 ether);
        // Bob offers 0.001 ETH but a tight price limit lets the pool take only a sliver of it.
        uint160 price = currentSqrtPrice();
        uint256 reserved = fee(0.001 ether);
        BalanceDelta delta = buyWithLimit(bob, -int256(0.001 ether), price - price / 1e12);
        uint256 paid = uint256(uint128(-delta.amount0()));
        assertGt(delta.amount1(), 0, "Bob did receive tokens");
        assertLt(paid, 0.001 ether, "the fill is dust");
        // The buyer settled pool ETH plus the whole reservation; the hook keeps 2% of the real spend.
        uint256 poolEth = paid - reserved;
        uint256 due = poolEth * 200 / 9800;
        assertGt(due, 0);
        assertEq(hook.cumulativeFees(), fee(1 ether) + due, "fee on executed ETH only");
        assertEq(hook.owed(bob), reserved - due, "the unused reservation is Bob's");
        assertEq(hook.totalOwed(), reserved - due);
        assertEq(hook.latestBuyer(), alice, "a dust fill does not take the position");
        assertEq(hook.buyCount(), 2);
        assertEq(hook.buyAt(1).latestBuyer, alice);
        assertBacked();

        vm.prank(bob);
        vm.expectEmit(true, false, false, true);
        emit HamsterNap3D.OwedWithdrawn(bob, reserved - due);
        hook.withdrawOwed();
        assertEq(bob.balance, reserved - due);
        assertEq(hook.totalOwed(), 0);
        assertBacked();

        // Alice, not Bob, wins the nap that follows.
        workThrough(650, 650);
        sleepThrough(651, 653);
        warpToRound(654);
        uint256 potBefore = hook.pot();
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, potBefore);
        assertEq(hook.pot(), 0);
        assertBacked();
    }

    function test_partialFillEmitsExecutedAmountsAndRefund() public {
        uint160 price = currentSqrtPrice();
        uint256 reserved = fee(0.001 ether);
        // Dry run on a snapshot to learn the fill, then expect exactly those figures in the events.
        uint256 snapshot = vm.snapshotState();
        BalanceDelta delta = buyWithLimit(bob, -int256(0.001 ether), price - price / 1e12);
        uint256 poolEth = uint256(uint128(-delta.amount0())) - reserved;
        vm.revertToState(snapshot);
        uint256 due = poolEth * 200 / 9800;

        vm.expectEmit(true, false, false, true);
        emit HamsterNap3D.FeeRefunded(bob, reserved - due);
        vm.expectEmit(true, false, false, true);
        emit HamsterNap3D.Buy(bob, poolEth + due, due, 650, false);
        buyWithLimit(bob, -int256(0.001 ether), price - price / 1e12);
    }

    function test_partialFillThatStillSpendsEnoughQualifies() public {
        buy(alice, 1 ether);
        // Bob offers 10 ETH; the limit stops the pool after roughly 1 ETH.
        uint160 price = currentSqrtPrice();
        uint256 reserved = fee(10 ether);
        BalanceDelta delta = buyWithLimit(bob, -int256(10 ether), price - price / 1e6);
        uint256 paid = uint256(uint128(-delta.amount0()));
        assertLt(paid, 10 ether, "partial");
        uint256 poolEth = paid - reserved;
        uint256 due = poolEth * 200 / 9800;
        assertGe(poolEth + due, 0.001 ether);
        assertEq(hook.cumulativeFees(), fee(1 ether) + due);
        assertEq(hook.owed(bob), reserved - due);
        assertEq(hook.latestBuyer(), bob, "a partial fill above the threshold still qualifies");
        assertBacked();
    }

    function test_nearZeroFillRefundsTheWholeReservationAndRecordsNothing() public {
        buy(alice, 1 ether);
        uint160 price = currentSqrtPrice();
        uint256 reserved = fee(1 ether);
        // One tick of sqrt price: the pool fills a few wei at most, too little for a 1 wei fee.
        BalanceDelta delta = buyWithLimit(bob, -int256(1 ether), price - 1);
        uint256 poolEth = uint256(uint128(-delta.amount0())) - reserved;
        assertLt(poolEth, 49, "no fee is due on so small a fill");
        assertEq(hook.cumulativeFees(), fee(1 ether), "no fee charged");
        assertEq(hook.owed(bob), reserved, "the whole reservation comes back");
        assertEq(hook.buyCount(), 1, "nothing recorded");
        assertEq(hook.latestBuyer(), alice);
        assertBacked();
    }

    function test_partialExactOutputFillPaysFeeOnExecutedEth() public {
        buy(alice, 1 ether);
        uint160 price = currentSqrtPrice();
        BalanceDelta delta = buyWithLimit(bob, int256(1_000_000 ether), price - price / 1e9);
        assertLt(delta.amount1(), 1_000_000 ether, "partial output");
        uint256 gross = uint256(uint128(-delta.amount0()));
        uint256 due = hook.cumulativeFees() - fee(1 ether);
        assertApproxEqAbs(due, gross * 200 / 10_000, 1, "2% of what was spent");
        assertEq(hook.owed(bob), 0, "exact output never over-reserves");
        assertEq(hook.latestBuyer(), gross >= 0.001 ether ? bob : alice);
        assertBacked();
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_partialFillFeeIsTwoPercentOfExecutedEth(uint96 offered, uint32 limitSteps) public {
        buy(alice, 1 ether);
        uint256 amount = bound(uint256(offered), 50, 100 ether);
        // A limit between one tick below the price and one percent below it.
        uint160 price = currentSqrtPrice();
        uint256 steps = bound(uint256(limitSteps), 1, 1e6);
        uint160 limit = uint160(uint256(price) - uint256(price) / 100 * steps / 1e6);
        if (limit >= price) limit = price - 1;
        uint256 reserved = fee(amount);
        BalanceDelta delta = buyWithLimit(bob, -int256(amount), limit);
        uint256 paid = uint256(uint128(-delta.amount0()));
        assertLe(paid, amount);
        uint256 poolEth = paid - reserved;
        uint256 due = hook.cumulativeFees() - fee(1 ether);
        if (paid == amount) {
            assertEq(due, reserved, "a full fill pays the reservation");
            assertEq(hook.owed(bob), 0);
        } else {
            assertEq(due, poolEth * 200 / 9800 > reserved ? reserved : poolEth * 200 / 9800);
            assertEq(hook.owed(bob), reserved - due);
        }
        assertEq(hook.latestBuyer(), poolEth + due >= 0.001 ether ? bob : alice);
        assertBacked();
    }

    // ---------------------------------------------------------------- claims

    function test_claimBeforeAnySwapReverts() public {
        vm.expectRevert(HamsterNap3D.GameNotStarted.selector);
        hook.settleNaps(1);
        vm.expectRevert(HamsterNap3D.GameNotStarted.selector);
        hook.failsafe();
        vm.expectRevert(HamsterNap3D.ZeroPages.selector);
        hook.settleNaps(0);
    }

    function test_roundBoundary_lastSecondBeforeNapCounts_firstSecondDoesNot() public {
        uint64 s = 660;
        vm.warp(roundStart(s) - 1);
        buy(alice, 1 ether); // round s-1: counts
        vm.warp(roundStart(s));
        buy(bob, 2 ether); // round s: does not
        assertEq(hook.buyAt(0).round, s - 1);
        assertEq(hook.buyAt(1).round, s);

        workThrough(650, s - 1);
        sleepThrough(s, s + 2);
        warpToRound(s + 4);

        vm.expectEmit(true, true, false, true);
        emit HamsterNap3D.NapSettled(s, alice, fee(1 ether));
        uint256 settled = hook.settleNaps(10);
        assertEq(settled, 1);
        assertEq(alice.balance, fee(1 ether));
        assertEq(hook.pot(), fee(2 ether), "bob's fee stays for the next game");
        assertEq(hook.latestBuyer(), bob);
        assertTrue(hook.firstNapSettled());
        assertEq(hook.napsSettled(), 1);
        assertBacked();
    }

    function test_napOfTwoRoundsPaysNothing() public {
        warpToRound(655);
        buy(alice, 1 ether);
        workThrough(650, 659);
        sleepThrough(660, 661);
        workThrough(662, 670);
        warpToRound(671);
        assertEq(hook.settleNaps(10), 0);
        assertEq(hook.napsSettled(), 0);
        assertEq(alice.balance, 0);
        assertEq(hook.pot(), fee(1 ether));
        assertEq(hook.scanRound(), 671);
        assertFalse(hook.firstNapSettled());
    }

    function test_napOfThreeRoundsPays() public {
        warpToRound(655);
        buy(alice, 1 ether);
        workThrough(650, 659);
        sleepThrough(660, 662);
        warpToRound(663);
        assertEq(hook.settleNaps(10), 1);
        assertEq(alice.balance, fee(1 ether));
        assertEq(hook.pot(), 0);
    }

    function test_napNotYetFullySettledWaits() public {
        warpToRound(655);
        buy(alice, 1 ether);
        workThrough(650, 659);
        sleepThrough(660, 661); // frontier at 661: two zero rounds certified so far
        warpToRound(663);
        assertEq(hook.settleNaps(10), 0);
        assertEq(hook.zeroRun(), 2);
        assertEq(hook.zeroRunStart(), 660);
        assertEq(hook.scanRound(), 662);
        assertEq(alice.balance, 0);

        sleepThrough(662, 662); // the third round settles
        assertEq(hook.settleNaps(10), 1);
        assertEq(alice.balance, fee(1 ether));
    }

    function test_longNapPaysOnce() public {
        warpToRound(655);
        buy(alice, 1 ether);
        workThrough(650, 659);
        sleepThrough(660, 700);
        warpToRound(701);
        assertEq(hook.settleNaps(10), 1);
        buy(bob, 1 ether); // a buy during the still-running nap
        sleepThrough(701, 720);
        warpToRound(721);
        assertEq(hook.settleNaps(10), 0, "the same nap does not pay again");
        assertEq(hook.pot(), fee(1 ether));
        assertEq(hook.napsSettled(), 1);
    }

    function test_buysDuringNapCountForNextGame() public {
        uint64 s = 660;
        warpToRound(655);
        buy(alice, 1 ether);
        warpToRound(s + 1);
        buy(carol, 3 ether); // during the nap, before it is settled
        workThrough(650, s - 1);
        sleepThrough(s, s + 2);
        warpToRound(s + 3);
        hook.settleNaps(10);
        assertEq(alice.balance, fee(1 ether));
        assertEq(hook.pot(), fee(3 ether));
        assertEq(hook.latestBuyer(), carol);

        // The hamster wakes, then naps again: carol wins the second game.
        workThrough(s + 3, s + 10);
        sleepThrough(s + 11, s + 13);
        warpToRound(s + 14);
        hook.settleNaps(10);
        assertEq(carol.balance, fee(3 ether));
        assertEq(hook.pot(), 0);
        assertEq(hook.napsSettled(), 2);
        assertBacked();
    }

    function test_severalNapsClaimedInOrderInOneCall() public {
        warpToRound(651);
        buy(alice, 1 ether);
        warpToRound(671);
        buy(bob, 2 ether);
        warpToRound(691);
        buy(carol, 4 ether);
        workThrough(650, 659);
        sleepThrough(660, 665);
        workThrough(666, 679);
        sleepThrough(680, 682);
        workThrough(683, 699);
        sleepThrough(700, 702);
        workThrough(703, 705);
        warpToRound(706);

        vm.expectEmit(true, true, false, true);
        emit HamsterNap3D.NapSettled(660, alice, fee(1 ether));
        vm.expectEmit(true, true, false, true);
        emit HamsterNap3D.NapSettled(680, bob, fee(2 ether));
        vm.expectEmit(true, true, false, true);
        emit HamsterNap3D.NapSettled(700, carol, fee(4 ether));
        assertEq(hook.settleNaps(10), 3);
        assertEq(alice.balance, fee(1 ether));
        assertEq(bob.balance, fee(2 ether));
        assertEq(carol.balance, fee(4 ether));
        assertEq(hook.pot(), 0);
        assertEq(hook.scanRound(), 706);
        assertBacked();
    }

    function test_paginationKeepsProgressAcrossCalls() public {
        warpToRound(651);
        buy(alice, 1 ether);
        workThrough(650, 699);
        sleepThrough(700, 702);
        warpToRound(703);
        assertEq(hook.settleNaps(1), 0);
        assertEq(hook.scanRound(), 667, "16 rounds from 651");
        assertEq(hook.settleNaps(1), 0);
        assertEq(hook.scanRound(), 683);
        assertEq(hook.settleNaps(2), 1);
        assertEq(hook.scanRound(), 703);
        assertEq(alice.balance, fee(1 ether));
        // Nothing more to scan: a call is harmless.
        assertEq(hook.settleNaps(5), 0);
        assertEq(hook.scanRound(), 703);
    }

    function test_napWithNoQualifyingBuyerKeepsPot() public {
        warpToRound(651);
        buy(alice, 0.0001 ether); // dust only: a pot, no qualifying buyer
        workThrough(650, 659);
        sleepThrough(660, 662);
        warpToRound(663);
        vm.expectEmit(true, true, false, true);
        emit HamsterNap3D.NapSettled(660, address(0), 0);
        assertEq(hook.settleNaps(10), 1);
        assertEq(hook.pot(), fee(0.0001 ether), "the pot waits for a qualifying buyer");
        assertTrue(hook.firstNapSettled());
    }

    function test_winnerBeforeView() public {
        warpToRound(651);
        buy(alice, 1 ether);
        warpToRound(655);
        buy(bob, 2 ether);
        (address w, uint256 a) = hook.winnerBefore(652);
        assertEq(w, alice);
        assertEq(a, fee(1 ether));
        (w, a) = hook.winnerBefore(656);
        assertEq(w, bob);
        assertEq(a, fee(3 ether));
        (w, a) = hook.winnerBefore(651);
        assertEq(w, address(0));
        assertEq(a, 0);
    }

    // ---------------------------------------------------------------- failsafe

    function test_failsafePaysLastQualifyingBuyerAfterSevenStaleDays() public {
        uint256 firstSeen = block.timestamp;
        buy(alice, 1 ether);
        vm.warp(block.timestamp + 1 hours);
        buy(bob, 0.5 ether); // the frontier did not move: the clock still runs from the first sighting
        assertEq(hook.lastSeenFrontier(), 649);
        assertEq(hook.frontierSeenAt(), firstSeen);
        uint256 opensAt = firstSeen + 7 days;
        assertGt(opensAt, roundEnd(649) + 7 days, "the sighting, 17 seconds into round 650, is the later date");
        assertEq(hook.failsafeOpensAt(), opensAt);

        vm.warp(opensAt - 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, opensAt));
        hook.failsafe();

        vm.warp(opensAt);
        vm.prank(carol); // anyone may trigger it; only the last qualifying buyer is paid
        vm.expectEmit(true, false, false, true);
        emit HamsterNap3D.FailsafeTaken(bob, fee(1.5 ether), 649);
        hook.failsafe();
        assertEq(bob.balance, fee(1.5 ether));
        assertEq(hook.pot(), 0);
        assertBacked();

        vm.expectRevert(HamsterNap3D.NothingToPay.selector);
        hook.failsafe();
    }

    function test_failsafeNotOpenWhileCoreAdvances() public {
        buy(alice, 1 ether);
        vm.warp(roundEnd(649) + 7 days);
        // The core kept settling: its frontier is current. The failsafe reads it, sees the advance
        // for the first time now, and stays shut for another seven days.
        uint64 current = hook.currentRound();
        workThrough(650, current - 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, block.timestamp + 7 days));
        hook.failsafe();
        // The reverted call kept nothing; a claim call records the same sighting.
        hook.settleNaps(1);
        assertEq(hook.lastSeenFrontier(), current - 1);
        assertEq(hook.frontierSeenAt(), block.timestamp);
        assertEq(hook.failsafeOpensAt(), block.timestamp + 7 days);
    }

    function test_failsafeRestartsWhenABuyObservesAFreshAdvance() public {
        // Round 650, frontier 649. Nobody touches the hook for eight days while the core catches up.
        buy(alice, 1 ether);
        assertEq(hook.lastSeenFrontier(), 649);
        vm.warp(block.timestamp + 8 days);
        // The core advances one round, far behind the clock. Bob's buy observes the advance.
        core.setFrontier(650);
        buy(bob, 0.001 ether);
        assertEq(hook.lastSeenFrontier(), 650);
        assertEq(hook.frontierSeenAt(), block.timestamp);
        uint256 opensAt = block.timestamp + 7 days;
        assertEq(hook.failsafeOpensAt(), opensAt);
        // Round 650 ended more than eight days ago, but the frontier moved just now: not stale.
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, opensAt));
        hook.failsafe();
        vm.warp(opensAt - 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, opensAt));
        hook.failsafe();
        // Seven unchanged days later the pot goes to the last qualifying buyer.
        vm.warp(opensAt);
        vm.expectEmit(true, false, false, true);
        emit HamsterNap3D.FailsafeTaken(bob, fee(1.001 ether), 650);
        hook.failsafe();
        assertEq(bob.balance, fee(1.001 ether));
        assertBacked();
    }

    function test_failsafeRestartsWhenItObservesAFreshAdvanceItself() public {
        buy(alice, 1 ether);
        vm.warp(block.timestamp + 8 days);
        core.setFrontier(650);
        // No swap or claim saw the advance; the failsafe call itself does, and stays shut.
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, block.timestamp + 7 days));
        hook.failsafe();
        // A claim call that finds no nap still records the sighting and restarts the clock the same way.
        vm.warp(block.timestamp + 6 days);
        core.setFrontier(651);
        assertEq(hook.settleNaps(1), 0);
        assertEq(hook.lastSeenFrontier(), 651);
        assertEq(hook.frontierSeenAt(), block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, block.timestamp + 7 days));
        hook.failsafe();
    }

    function test_failsafeWorksWhenCoreReverts() public {
        buy(alice, 1 ether);
        core.setReverting(true);
        // The core stopped answering right after the buy that saw frontier 649: dated from that buy.
        vm.warp(hook.failsafeOpensAt() - 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, hook.failsafeOpensAt()));
        hook.failsafe();
        vm.warp(hook.failsafeOpensAt());
        hook.failsafe();
        assertEq(alice.balance, fee(1 ether));
    }

    function test_failsafeWithNeverReadableCoreDatesFromTheGameStart() public {
        // The core has no code from the start: the frontier stays at zero and nothing is observed.
        vm.etch(address(core), "");
        vm.warp(roundStart(700) + 5);
        uint256 gameStart = block.timestamp;
        buy(alice, 1 ether);
        assertEq(hook.lastSeenFrontier(), 0);
        assertEq(hook.frontierSeenAt(), gameStart);
        // Genesis is long past, but the clock runs from the game's start, not from round zero's end.
        assertEq(hook.failsafeOpensAt(), gameStart + 7 days);
        vm.warp(gameStart + 7 days - 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, gameStart + 7 days));
        hook.failsafe();
        vm.warp(gameStart + 7 days);
        hook.failsafe();
        assertEq(alice.balance, fee(1 ether));
    }

    function test_failsafeNeedsAQualifyingBuyer() public {
        buy(alice, 0.0001 ether);
        vm.warp(hook.failsafeOpensAt());
        vm.expectRevert(HamsterNap3D.NoQualifyingBuyer.selector);
        hook.failsafe();
    }

    /// A nap the core certified before it stalled belongs to that nap's winner, not to whoever bought
    /// last: the failsafe settles it first and pays only the fees collected after it.
    function test_failsafeSettlesCertifiedNapsBeforePaying() public {
        buy(alice, 1 ether); // round 650: alice is the last buyer before the nap at 651
        workThrough(650, 650);
        sleepThrough(651, 653); // certified: a nap at 651 that alice wins
        warpToRound(660);
        buy(bob, 0.05 ether); // observes frontier 653, then the core stalls; nobody calls settleNaps
        assertEq(hook.lastSeenFrontier(), 653);
        assertEq(hook.scanRound(), 650);
        vm.warp(hook.failsafeOpensAt());

        (address winner, uint256 amount) = hook.failsafeWinner();
        assertEq(winner, bob);
        assertEq(amount, fee(1.05 ether), "the view shows the pot before the certified nap is paid");

        vm.expectEmit(true, true, false, true);
        emit HamsterNap3D.NapSettled(651, alice, fee(1 ether));
        vm.expectEmit(true, false, false, true);
        emit HamsterNap3D.FailsafeTaken(bob, fee(0.05 ether), 653);
        vm.prank(carol);
        hook.failsafe();
        assertEq(alice.balance, fee(1 ether), "the certified nap's pot went to its winner");
        assertEq(bob.balance, fee(0.05 ether), "the failsafe paid only what came after it");
        assertEq(hook.napsSettled(), 1);
        assertEq(hook.scanRound(), 654);
        assertEq(hook.pot(), 0);
        assertBacked();
        // The nap is not paid twice by a later claim call.
        assertEq(hook.settleNaps(1), 0);
        assertEq(alice.balance, fee(1 ether));
    }

    /// A backlog longer than the failsafe scans itself must be worked through with settleNaps first;
    /// the failsafe then pays what the naps in it left.
    function test_failsafeRefusesToPayOverALongUnsettledBacklog() public {
        buy(alice, 1 ether); // round 650, before every nap below
        workThrough(650, 659);
        sleepThrough(660, 662); // nap at 660: alice's
        workThrough(663, 999); // 350 rounds certified: 22 pages, more than FAILSAFE_SCAN_PAGES
        warpToRound(1000);
        buy(bob, 0.5 ether); // observes frontier 999; the core stalls here
        vm.warp(hook.failsafeOpensAt());

        uint64 pages = uint64(hook.FAILSAFE_SCAN_PAGES());
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.NapsUnsettled.selector, 650 + pages * 16, 999));
        hook.failsafe();
        // The reverted call kept no progress; the nap in the backlog is still alice's.
        assertEq(hook.scanRound(), 650);
        assertEq(alice.balance, 0);
        hook.settleNaps(30);
        assertEq(hook.scanRound(), 1000);
        assertEq(alice.balance, fee(1 ether));
        hook.failsafe();
        assertEq(bob.balance, fee(0.5 ether));
        assertEq(hook.pot(), 0);
        assertBacked();
    }

    /// When the core cannot be read at all, nothing in the unscanned range can be certified, so the
    /// failsafe pays the whole pot: a reverting core and a core whose code is gone.
    function test_failsafePaysEverythingWhenTheBacklogCannotBeRead() public {
        buy(alice, 1 ether);
        workThrough(650, 650);
        sleepThrough(651, 653);
        warpToRound(660);
        buy(bob, 0.05 ether); // sees frontier 653; scanRound stays at 650
        vm.warp(hook.failsafeOpensAt());
        core.setReverting(true);
        uint256 snapshot = vm.snapshotState();

        hook.failsafe();
        assertEq(bob.balance, fee(1.05 ether));
        assertEq(hook.napsSettled(), 0, "nothing could be certified");
        assertEq(hook.scanRound(), 650);
        assertBacked();

        vm.revertToState(snapshot);
        vm.etch(address(core), ""); // a codeless core answers with empty data that does not decode
        hook.failsafe();
        assertEq(bob.balance, fee(1.05 ether));
        assertEq(hook.napsSettled(), 0);
        assertBacked();
    }

    /// A buy placed after the failsafe's cutoff (alone, or in the same transaction as the failsafe
    /// call) pays its fee into the pot and wins nothing now, so the pot cannot be sniped for 0.001 ETH.
    /// Its fee waits in the pot and goes, seven days later, to the buyer who was last when it was paid.
    function test_buyAfterTheFailsafeOpenedDoesNotTakeThePot() public {
        buy(alice, 1 ether);
        uint256 opensAt = hook.failsafeOpensAt();
        assertEq(hook.failsafeCutoff(), opensAt, "before the opening the cutoff is the opening");
        vm.warp(opensAt - 1);
        buy(bob, 0.001 ether); // the last second before the failsafe opens still counts
        vm.warp(opensAt);
        buy(dave, 0.001 ether); // too late: the failsafe is open
        assertEq(hook.latestBuyer(), dave, "for the next nap dave is the latest buyer");
        assertEq(hook.failsafeCutoff(), opensAt);
        (address winner, uint256 amount) = hook.failsafeWinner();
        assertEq(winner, bob);
        assertEq(amount, fee(1.001 ether), "dave's fee is not in what bob takes");

        vm.warp(opensAt + 1 days);
        buy(carol, 0.001 ether);
        vm.expectEmit(true, false, false, true);
        emit HamsterNap3D.FailsafeTaken(bob, fee(1.001 ether), 649);
        vm.prank(carol);
        hook.failsafe();
        assertEq(bob.balance, fee(1.001 ether));
        assertEq(dave.balance, 0);
        assertEq(carol.balance, 0);
        assertEq(hook.pot(), fee(0.002 ether), "the late buys' fees wait in the pot");
        assertBacked();

        // Nothing more is payable until a late buy is seven days old.
        vm.warp(opensAt + 7 days);
        assertEq(hook.failsafeCutoff(), opensAt, "dave's buy at the opening is not yet before the cutoff");
        vm.expectRevert(HamsterNap3D.NothingToPay.selector);
        hook.failsafe();
        vm.warp(opensAt + 7 days + 1);
        assertEq(hook.failsafeCutoff(), opensAt + 1);
        (winner, amount) = hook.failsafeWinner();
        assertEq(winner, dave);
        assertEq(amount, fee(0.001 ether));
        vm.expectEmit(true, false, false, true);
        emit HamsterNap3D.FailsafeTaken(dave, fee(0.001 ether), 649);
        hook.failsafe();
        assertEq(dave.balance, fee(0.001 ether));
        vm.warp(opensAt + 8 days + 1);
        hook.failsafe();
        assertEq(carol.balance, fee(0.001 ether));
        assertEq(hook.pot(), 0);
        assertBacked();
    }

    /// With a core that never returns, the failsafe's cutoff keeps rolling: a buyer who qualifies
    /// after an earlier failsafe payout is paid the fees collected through their buy once it is seven
    /// days old, and the earlier winner is never paid again.
    function test_failsafePaysLaterQualifyingBuyersAsTheirBuysAge() public {
        buy(alice, 1 ether);
        core.setReverting(true); // dead from here on: the frontier and the opening never move
        uint256 opensAt = hook.failsafeOpensAt();
        vm.warp(opensAt);
        hook.failsafe();
        assertEq(alice.balance, fee(1 ether));
        assertEq(hook.pot(), 0);

        vm.warp(opensAt + 1 days);
        buy(bob, 1 ether); // the last qualifying buyer, a day after the first payout
        assertEq(hook.latestBuyer(), bob);
        assertEq(hook.failsafeOpensAt(), opensAt, "the opening is frozen with the core");
        assertEq(hook.failsafeCutoff(), opensAt, "the cutoff has not reached bob's buy yet");
        (address winner, uint256 amount) = hook.failsafeWinner();
        assertEq(winner, alice);
        assertEq(amount, 0, "alice was paid through her last buy; bob's fee is not hers");
        vm.expectRevert(HamsterNap3D.NothingToPay.selector);
        hook.failsafe();

        vm.warp(opensAt + 8 days); // bob's buy is exactly seven days old: not yet before the cutoff
        assertEq(hook.failsafeCutoff(), opensAt + 1 days);
        vm.expectRevert(HamsterNap3D.NothingToPay.selector);
        hook.failsafe();

        vm.warp(opensAt + 8 days + 1);
        (winner, amount) = hook.failsafeWinner();
        assertEq(winner, bob);
        assertEq(amount, fee(1 ether));
        vm.prank(carol); // anyone may trigger it
        vm.expectEmit(true, false, false, true);
        emit HamsterNap3D.FailsafeTaken(bob, fee(1 ether), 649);
        hook.failsafe();
        assertEq(bob.balance, fee(1 ether), "the last qualifying buyer takes the pot");
        assertEq(alice.balance, fee(1 ether), "the first failsafe winner is not paid again");
        assertEq(hook.pot(), 0);
        assertBacked();
    }

    /// No qualifying buyer when the failsafe opened (dust only): the first buyer who qualifies later
    /// is paid, the dust fees included, once their buy is seven days old, instead of nothing ever
    /// leaving the hook.
    function test_failsafeWithNoBuyerAtTheOpeningPaysTheFirstLaterQualifyingBuyer() public {
        buy(alice, 0.0005 ether); // dust: a fee, no latest buyer
        core.setReverting(true);
        uint256 opensAt = hook.failsafeOpensAt();
        vm.warp(opensAt + 1);
        vm.expectRevert(HamsterNap3D.NoQualifyingBuyer.selector);
        hook.failsafe();
        buy(bob, 1 ether); // the only qualifying buyer, after the opening
        assertEq(hook.latestBuyer(), bob);
        vm.expectRevert(HamsterNap3D.NoQualifyingBuyer.selector);
        hook.failsafe(); // bob's buy is not seven days old yet
        vm.warp(opensAt + 7 days + 2);
        vm.expectEmit(true, false, false, true);
        emit HamsterNap3D.FailsafeTaken(bob, fee(1.0005 ether), 649);
        hook.failsafe();
        assertEq(bob.balance, fee(1.0005 ether), "the dust fee comes with it");
        assertEq(hook.pot(), 0);
        assertBacked();
    }

    /// A buy after the failsafe opened still counts for a nap if the core turns out to be alive.
    function test_buyAfterTheFailsafeOpenedStillCountsForALaterNap() public {
        buy(alice, 1 ether);
        vm.warp(hook.failsafeOpensAt() + 1);
        buy(bob, 0.5 ether); // excluded from the failsafe, but the latest buyer for nap purposes
        (address winner,) = hook.failsafeWinner();
        assertEq(winner, alice);
        // The core was running all along; a claim call sees the advance and the failsafe shuts.
        uint64 bought = hook.currentRound();
        workThrough(650, bought);
        warpToRound(bought + 1);
        hook.settleNaps(1);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, hook.failsafeOpensAt()));
        hook.failsafe();
        // A nap after bob's buy pays bob.
        sleepThrough(bought + 1, bought + 3);
        warpToRound(bought + 4);
        hook.settleNaps(100);
        assertEq(bob.balance, fee(1.5 ether));
        assertBacked();
    }

    function test_settleNapsRevertsWhenTheCoreCannotBeRead() public {
        uint256 gameStart = block.timestamp;
        buy(alice, 1 ether);
        core.setReverting(true);
        vm.expectRevert(HamsterNap3D.CoreUnreadable.selector);
        hook.settleNaps(1);
        core.setReverting(false);
        // A core whose state reads but whose pages no longer decode: claims revert. The frontier it
        // reports keeps the frontier clock fresh, so the failsafe call that finds the shut clock and
        // the unreadable page records the failure and returns; the page clock opens it a week later.
        vm.etch(address(core), address(new HalfReadableCore()).code);
        vm.warp(roundEnd(653));
        vm.expectRevert(HamsterNap3D.CoreUnreadable.selector);
        hook.settleNaps(1);
        assertEq(hook.lastSeenFrontier(), 649, "the reverted claim recorded nothing");
        uint256 noticedAt = block.timestamp;
        vm.expectEmit(false, false, false, true);
        emit HamsterNap3D.PageFailureSeen(650, 653, noticedAt + 7 days);
        hook.failsafe();
        assertEq(hook.pageFailureSeenAt(), noticedAt);
        assertEq(hook.lastSeenFrontier(), 653, "the recording call kept the sighting");
        assertEq(hook.frontierSeenAt(), noticedAt);
        assertEq(hook.failsafeOpensAt(), noticedAt + 7 days);
        assertEq(alice.balance, 0);
        assertEq(hook.pot(), fee(1 ether));
        vm.warp(noticedAt + 7 days - 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, noticedAt + 7 days));
        hook.failsafe();
        vm.warp(noticedAt + 7 days);
        vm.expectEmit(true, false, false, true);
        emit HamsterNap3D.FailsafeTaken(alice, fee(1 ether), 653);
        hook.failsafe();
        assertEq(alice.balance, fee(1 ether));
        assertEq(hook.napsSettled(), 0, "nothing behind the frontier could be certified");
        assertEq(hook.scanRound(), 650);
        assertGt(block.timestamp, gameStart + 7 days);
        assertBacked();
    }

    // ---------------------------------------------------------------- a reverting or paused core

    function test_sellsAndBuysWorkWhileCoreReverts() public {
        buy(alice, 1 ether);
        core.setReverting(true);
        BalanceDelta sold = sell(bob, 100 ether);
        assertGt(sold.amount0(), 0);
        buy(carol, 1 ether);
        assertEq(hook.latestBuyer(), carol);
        assertEq(hook.pot(), fee(2 ether));
        vm.expectRevert();
        hook.settleNaps(1);
        core.setReverting(false);
        hook.settleNaps(1);
    }

    function test_coreWithNoCodeDoesNotBreakSwaps() public {
        vm.etch(address(core), "");
        buy(alice, 1 ether);
        sell(bob, 100 ether);
        assertEq(hook.lastSeenFrontier(), 0);
    }

    function test_pausedCoreStillReads() public {
        core.setPaused(true);
        buy(alice, 1 ether);
        sell(bob, 100 ether);
        assertEq(hook.lastSeenFrontier(), 649);
        assertEq(hook.settleNaps(1), 0);
    }

    // ---------------------------------------------------------------- a winner that rejects ETH

    function test_winnerThatRejectsEthIsCreditedAndDoesNotBlock() public {
        RejectingWinner rejecting = new RejectingWinner();
        warpToRound(651);
        buy(address(rejecting), 1 ether); // the last qualifying buyer before the nap at 660
        warpToRound(665);
        buy(bob, 2 ether); // the last one before the nap at 670
        workThrough(650, 659);
        sleepThrough(660, 662);
        workThrough(663, 669);
        sleepThrough(670, 672);
        warpToRound(673);

        vm.expectEmit(true, false, false, true);
        emit HamsterNap3D.PayoutDeferred(address(rejecting), fee(1 ether));
        assertEq(hook.settleNaps(10), 2, "the second nap still settled");
        assertEq(hook.owed(address(rejecting)), fee(1 ether));
        assertEq(hook.totalOwed(), fee(1 ether));
        assertEq(bob.balance, fee(2 ether));
        assertEq(hook.pot(), 0);
        assertBacked();

        vm.expectRevert(HamsterNap3D.TransferFailed.selector);
        rejecting.withdrawFrom(address(hook));
        rejecting.setAccepting(true);
        rejecting.withdrawFrom(address(hook));
        assertEq(address(rejecting).balance, fee(1 ether));
        assertEq(hook.totalOwed(), 0);
        assertBacked();

        vm.expectRevert(HamsterNap3D.NothingOwed.selector);
        hook.withdrawOwed();
    }

    /// A winner whose wallet (an EOA carrying EIP-7702 code) answers the payout with a payload sized to
    /// the gas it was given cannot stall the claim: the payout copies no return data and gives the
    /// wallet bounded gas, so it is credited in `owed` and the nap, and every nap after it, settles.
    function test_returnBombWinnerIsCreditedAndDoesNotBlockClaims() public {
        ReturnBombWinner bomber = new ReturnBombWinner();
        warpToRound(651);
        buy(address(bomber), 1 ether); // the last qualifying buyer before the nap at 660
        warpToRound(665);
        buy(bob, 2 ether); // the last one before the nap at 670
        workThrough(650, 659);
        sleepThrough(660, 662);
        workThrough(663, 669);
        sleepThrough(670, 672);
        warpToRound(673);

        // Reverting with the bomb, with the gas a Sepolia block allows and far more.
        uint256 snapshot = vm.snapshotState();
        vm.expectEmit(true, false, false, true);
        emit HamsterNap3D.PayoutDeferred(address(bomber), fee(1 ether));
        uint256 settled = hook.settleNaps{gas: 30_000_000}(10);
        assertEq(settled, 2, "both naps settled");
        assertEq(hook.owed(address(bomber)), fee(1 ether));
        assertEq(bob.balance, fee(2 ether));
        assertEq(hook.pot(), 0);
        assertBacked();

        // Returning the bomb instead of reverting: the transfer succeeds and nothing is copied.
        vm.revertToState(snapshot);
        bomber.setReturns(true);
        assertEq(hook.settleNaps{gas: 30_000_000}(10), 2);
        assertEq(address(bomber).balance + hook.owed(address(bomber)), fee(1 ether));
        assertEq(bob.balance, fee(2 ether));
        assertBacked();
    }

    /// The failsafe pays through the same bounded call, so the same wallet cannot stall it either, and
    /// a wallet that drops its code afterwards collects through `withdrawOwed`.
    function test_returnBombWinnerDoesNotBlockFailsafe() public {
        ReturnBombWinner bomber = new ReturnBombWinner();
        buy(address(bomber), 1 ether);
        vm.warp(hook.failsafeOpensAt());
        vm.expectEmit(true, false, false, true);
        emit HamsterNap3D.PayoutDeferred(address(bomber), fee(1 ether));
        hook.failsafe{gas: 30_000_000}();
        assertEq(hook.owed(address(bomber)), fee(1 ether));
        assertEq(hook.pot(), 0);
        assertBacked();

        vm.etch(address(bomber), ""); // the delegation is removed: a plain wallet again
        vm.prank(address(bomber));
        hook.withdrawOwed();
        assertEq(address(bomber).balance, fee(1 ether));
        assertEq(hook.totalOwed(), 0);
        assertBacked();
    }

    /// A payout gives the winner's wallet `PAYOUT_GAS` (plus the EVM's 2300 for a value transfer); a
    /// wallet that needs more is credited, not paid, and pulls its credit with all the gas it needs.
    function test_payoutGasIsBounded() public {
        GasProbeWinner probe = new GasProbeWinner();
        GasProbeWinner hungry = new GasProbeWinner();
        hungry.setBurn(150_000);
        warpToRound(651);
        buy(address(probe), 1 ether); // wins the nap at 660
        warpToRound(665);
        buy(address(hungry), 2 ether); // wins the nap at 670
        workThrough(650, 659);
        sleepThrough(660, 662);
        workThrough(663, 669);
        sleepThrough(670, 672);
        warpToRound(673);

        assertEq(hook.settleNaps(10), 2);
        assertEq(address(probe).balance, fee(1 ether));
        assertGt(probe.gasSeen(), 90_000, "an ordinary wallet gets the whole stipend");
        assertLe(probe.gasSeen(), hook.PAYOUT_GAS() + 2300, "never more than the stipend");
        assertEq(address(hungry).balance, 0);
        assertEq(hook.owed(address(hungry)), fee(2 ether), "credited: the payout gas ran out in the wallet");
        assertBacked();

        hungry.setBurn(0);
        hungry.withdrawFrom(address(hook));
        assertEq(address(hungry).balance, fee(2 ether));
        assertBacked();
    }

    // ---------------------------------------------------------------- accounting

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_potEqualsFeesInMinusPayouts(uint96[8] memory amounts, uint8 kinds) public {
        uint256 expectedFees;
        address[4] memory buyers = [alice, bob, carol, dave];
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = bound(uint256(amounts[i]), 1, 100 ether);
            uint8 kind = uint8((kinds >> (i * 2)) & 0x3) % 3;
            if (i == 0) kind = 0;
            if (kind == 0) {
                buy(buyers[i % 4], amount);
                expectedFees += fee(amount);
            } else if (kind == 1) {
                BalanceDelta d = buyExactOut(buyers[i % 4], amount);
                uint256 poolEth = uint256(uint128(-d.amount0()));
                uint256 f = hook.cumulativeFees() - expectedFees;
                assertApproxEqAbs(f, (poolEth - f) * 200 / 9800, 1);
                expectedFees += f;
            } else {
                sell(buyers[i % 4], amount);
            }
            assertEq(hook.cumulativeFees(), expectedFees);
            assertBacked();
        }
        workThrough(650, 659);
        sleepThrough(660, 662);
        warpToRound(663);
        uint256 potBefore = hook.pot();
        address winner = hook.latestBuyer();
        uint256 winnerBefore = winner.balance;
        assertEq(hook.settleNaps(10), 1);
        if (winner == address(0)) {
            // Only dust buys: the pot waits for a qualifying buyer.
            assertEq(hook.cumulativePaid(), 0);
            assertEq(hook.pot(), potBefore);
        } else {
            assertEq(hook.cumulativePaid(), potBefore);
            assertEq(winner.balance - winnerBefore, potBefore);
            assertEq(hook.pot(), 0);
        }
        assertBacked();
    }

    function test_reentrancyFromWinnerIsRefused() public {
        ReentrantWinner attacker = new ReentrantWinner(hook);
        warpToRound(651);
        buy(address(attacker), 1 ether);
        workThrough(650, 659);
        sleepThrough(660, 662);
        warpToRound(663);
        hook.settleNaps(10);
        // The re-entrant call was refused; the payout itself went through once.
        assertTrue(attacker.sawReentrancyRevert());
        assertEq(address(attacker).balance, fee(1 ether));
        assertEq(hook.owed(address(attacker)), 0);
        assertEq(hook.pot(), 0);
        assertBacked();
    }
}

/// @dev A wallet that records the gas a payout gives it and burns `burn` gas before accepting, so it
/// can stand for a wallet that needs more than the payout stipend.
contract GasProbeWinner {
    uint256 public gasSeen;
    uint256 public burn;
    uint256 private sink;

    function setBurn(uint256 value) external {
        burn = value;
    }

    receive() external payable {
        gasSeen = gasleft();
        uint256 start = gasleft();
        while (start - gasleft() < burn) {
            sink = start + gasleft();
        }
    }

    function withdrawFrom(address hook) external {
        (bool ok,) = hook.call(abi.encodeWithSignature("withdrawOwed()"));
        require(ok, "withdraw failed");
    }
}

/// @dev A core whose `state()` reads but whose `roundPage` answers with one bare word: the shape of a
/// core upgraded to another page ABI.
contract HalfReadableCore {
    function state() external pure returns (ISqueekCore.CoreState memory result) {
        result.settledThroughRound = 653;
    }

    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 32)
        }
    }
}

contract ReentrantWinner {
    HamsterNap3D private immutable hook;
    bool public sawReentrancyRevert;

    constructor(HamsterNap3D hook_) {
        hook = hook_;
    }

    receive() external payable {
        try hook.settleNaps(1) {}
        catch (bytes memory reason) {
            if (bytes4(reason) == HamsterNap3D.Reentrancy.selector) sawReentrancyRevert = true;
        }
        try hook.failsafe() {}
        catch (bytes memory reason) {
            if (bytes4(reason) != HamsterNap3D.Reentrancy.selector) sawReentrancyRevert = false;
        }
    }
}
