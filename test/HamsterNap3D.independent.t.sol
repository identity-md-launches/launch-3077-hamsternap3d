// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HamsterNap3D} from "src/HamsterNap3D.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";
import {HookTestBase} from "./HookTestBase.sol";
import {MockSqueekCore} from "./mocks/MockSqueekCore.sol";
import {RejectingWinner} from "./mocks/RejectingWinner.sol";

contract HamsterNap3DIndependentTest is HookTestBase {
    function setUp() public override {
        super.setUp();
        vm.chainId(11155111);
        seedBothSides(1_000_000 ether);
        core.setFrontier(649);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_lastSecondFirstSecondAndDust(uint96 beforeSeed, uint96 duringSeed, uint96 dustSeed) public {
        uint256 beforeNap = bound(beforeSeed, 0.001 ether, 10 ether);
        uint256 duringNap = bound(duringSeed, 0.001 ether, 10 ether);
        uint256 dust = bound(dustSeed, 1, 0.001 ether - 1);
        vm.warp(roundStart(651) - 1);
        buy(alice, beforeNap);
        buy(carol, dust); // fee belongs to Alice; Carol must not replace her
        warpToRound(651);
        buy(bob, duringNap);
        buy(dave, dust); // next-game fee, also not a new winner
        core.setWork(650, 1);
        core.setFrontier(652); // only two of the zero-work rounds are certified
        warpToRound(660); // wall time alone must not certify anything
        uint256 expectedFirst = beforeNap / 50 + dust / 50;
        uint256 expectedNext = duringNap / 50 + dust / 50;
        assertEq(hook.settleNaps(1), 0);
        assertEq(hook.scanRound(), 653);
        assertEq(hook.zeroRun(), 2);
        assertEq(hook.pot(), expectedFirst + expectedNext);
        assertEq(hook.latestBuyer(), bob);
        core.setFrontier(653);
        vm.expectEmit(true, true, false, true, address(hook));
        emit HamsterNap3D.NapSettled(651, alice, expectedFirst);
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, expectedFirst);
        assertEq(bob.balance, 0);
        assertEq(hook.pot(), expectedNext);
        assertEq(hook.settleNaps(100), 0, "replay cannot pay twice");
        core.setWork(654, 1);
        core.setFrontier(657);
        vm.expectEmit(true, true, false, true, address(hook));
        emit HamsterNap3D.NapSettled(655, bob, expectedNext);
        assertEq(hook.settleNaps(1), 1);
        assertEq(bob.balance, expectedNext);
        assertEq(hook.pot(), 0);
        assertBacked();
    }

    function test_pageBoundaryPreservesTwoZerosAndOrderedPayments() public {
        buy(alice, 1 ether); // scan starts at 650
        warpToRound(665);
        buy(bob, 2 ether); // inside first nap; must wait for the next one
        warpToRound(683);
        buy(carol, 4 ether); // inside second nap
        core.setWorkRange(650, 663, 1);
        core.setWorkRange(670, 680, 1);
        core.setWorkRange(686, 696, 1);
        core.setFrontier(699);
        warpToRound(700);
        assertEq(hook.settleNaps(1), 0); // 650..665: two zeros at page end
        assertEq(hook.zeroRun(), 2);
        assertEq(hook.settleNaps(1), 1); // 666..681: first nap paid
        assertEq(alice.balance, 0.02 ether);
        assertEq(bob.balance, 0);
        assertEq(hook.zeroRun(), 1);
        assertEq(hook.settleNaps(1), 1); // 682..697: second nap paid
        assertEq(bob.balance, 0.04 ether);
        assertEq(carol.balance, 0);
        assertEq(hook.settleNaps(1), 1);
        assertEq(carol.balance, 0.08 ether);
        assertEq(hook.napsSettled(), 3);
        assertEq(hook.scanRound(), 700);
        assertEq(hook.settleNaps(1), 0);
        assertBacked();
    }

    function test_laterPageFailureRollsBackEarlierPayoutAndScan() public {
        buy(alice, 1 ether);
        core.setWork(650, 1);
        core.setWork(660, 1);
        core.setFrontier(680);
        warpToRound(681);
        bytes memory pageTwo = abi.encodeCall(ISqueekCore.roundPage, (665, 680, 16));
        vm.mockCallRevert(address(core), pageTwo, abi.encodeWithSelector(MockSqueekCore.Reverting.selector));
        // A later unreadable page reverts the whole claim, so the nap found on page one is not paid
        // and the scan does not move past it.
        vm.expectRevert(HamsterNap3D.CoreUnreadable.selector);
        hook.settleNaps(2);
        assertEq(hook.scanRound(), 650);
        assertEq(hook.zeroRun(), 0);
        assertEq(hook.napsSettled(), 0);
        assertFalse(hook.firstNapSettled());
        assertEq(hook.cumulativePaid(), 0);
        assertEq(alice.balance, 0);
        assertEq(hook.pot(), 0.02 ether);
        assertBacked();
        vm.clearMockedCalls();
        assertEq(hook.settleNaps(2), 2);
        assertEq(alice.balance, 0.02 ether);
        assertEq(hook.scanRound(), 681);
    }

    function test_certifiedWorkBreaksTwoZeroRuns() public {
        buy(alice, 1 ether);
        core.setWork(650, 1);
        core.setWork(653, 1);
        core.setFrontier(655);
        warpToRound(657);
        assertEq(hook.settleNaps(1), 0, "two plus two is not a nap");
        assertEq(hook.zeroRunStart(), 654);
        assertEq(hook.zeroRun(), 2);
        core.setFrontier(656);
        vm.expectEmit(true, true, false, true, address(hook));
        emit HamsterNap3D.NapSettled(654, alice, 0.02 ether);
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, 0.02 ether);
    }

    function test_zeroFeeDustThresholdAndSameRoundOrdering() public {
        buy(alice, 0.001 ether);
        buy(bob, 49);
        assertEq(hook.buyCount(), 1);
        buy(bob, 50);
        assertEq(hook.cumulativeFees(), 0.00002 ether + 1);
        buy(carol, 0.001 ether - 1);
        assertEq(hook.latestBuyer(), alice);
        buy(dave, 0.001 ether);
        buy(bob, 50);
        (address winner, uint256 amount) = hook.winnerBefore(651);
        uint256 expected = 2 * (0.001 ether / 50) + uint256(0.001 ether - 1) / 50 + 2;
        assertEq(winner, dave, "last qualifying transaction in the same round wins");
        assertEq(amount, expected);
        core.setWork(650, 1);
        core.setFrontier(653);
        warpToRound(654);
        hook.settleNaps(1);
        assertEq(dave.balance, expected);
        assertBacked();
    }

    function test_rejectingWinnerAccumulatesTwoDebtsAndCannotLoseThemOnFailedWithdrawal() public {
        RejectingWinner winner = new RejectingWinner();
        buy(address(winner), 1 ether);
        warpToRound(654);
        buy(address(winner), 2 ether);
        warpToRound(658);
        buy(bob, 4 ether);
        core.setWork(650, 1);
        core.setWork(654, 1);
        core.setWork(658, 1);
        core.setFrontier(661);
        warpToRound(662);
        assertEq(hook.settleNaps(1), 3);
        assertEq(hook.owed(address(winner)), 0.06 ether);
        assertEq(bob.balance, 0.08 ether, "deferred debts must not block later winners");
        vm.expectRevert(HamsterNap3D.TransferFailed.selector);
        winner.withdrawFrom(address(hook));
        assertEq(hook.owed(address(winner)), 0.06 ether);
        assertEq(hook.totalOwed(), 0.06 ether);
        vm.prank(carol);
        vm.expectRevert(HamsterNap3D.NothingOwed.selector);
        hook.withdrawOwed();
        assertEq(hook.owed(address(winner)), 0.06 ether);
        winner.setAccepting(true);
        vm.expectEmit(true, false, false, true, address(hook));
        emit HamsterNap3D.OwedWithdrawn(address(winner), 0.06 ether);
        winner.withdrawFrom(address(hook));
        assertEq(address(winner).balance, 0.06 ether);
        vm.expectRevert(HamsterNap3D.NothingOwed.selector);
        winner.withdrawFrom(address(hook));
        assertEq(hook.totalOwed(), 0);
        assertBacked();
    }

    function test_failsafeDoesNotSpendDeferredNapDebt() public {
        RejectingWinner winner = new RejectingWinner();
        buy(address(winner), 1 ether);
        core.setWork(650, 1);
        core.setFrontier(653);
        warpToRound(654);
        hook.settleNaps(1);
        buy(bob, 2 ether);
        buy(carol, 0.0005 ether);
        core.setReverting(true);
        // Seven full days after the observation as well as the frontier's round end.
        vm.warp(block.timestamp + 7 days);
        vm.prank(dave);
        hook.failsafe();
        assertEq(bob.balance, 0.04 ether + 0.00001 ether);
        assertEq(hook.pot(), 0);
        assertEq(hook.totalOwed(), 0.02 ether);
        assertEq(address(hook).balance, 0.02 ether);
        vm.expectRevert(HamsterNap3D.NothingToPay.selector);
        hook.failsafe();
        winner.setAccepting(true);
        winner.withdrawFrom(address(hook));
        assertEq(address(winner).balance, 0.02 ether);
        assertBacked();
    }

    function test_failsafeThenCoreRecoveryCannotPayOldFeesAgain() public {
        buy(alice, 1 ether);
        core.setReverting(true);
        vm.warp(block.timestamp + 7 days);
        hook.failsafe();
        assertEq(alice.balance, 0.02 ether);
        buy(bob, 2 ether);
        uint64 boughtIn = hook.currentRound();
        core.setReverting(false);
        core.setWork(650, 1);
        core.setWork(boughtIn, 1); // wake after the old nap, then a new nap
        core.setFrontier(boughtIn + 3);
        warpToRound(boughtIn + 4);
        assertEq(hook.settleNaps(100), 2);
        assertEq(alice.balance, 0.02 ether);
        assertEq(bob.balance, 0.04 ether);
        assertEq(hook.cumulativePaid(), 0.06 ether);
        assertBacked();
    }

    function test_sellsAndLpFeeCollectNeverReadBrokenCore() public {
        buy(alice, 1 ether);
        core.setReverting(true);
        vm.expectCall(address(core), abi.encodeCall(ISqueekCore.state, ()), uint64(0));
        BalanceDelta exactIn = sell(bob, 0.001 ether);
        vm.prank(carol, carol);
        BalanceDelta exactOut = swapper.swapExact(key, false, int256(0.0001 ether));
        assertGt(exactIn.amount0(), 0);
        assertEq(exactOut.amount0(), 0.0001 ether);
        BalanceDelta collected =
            swapper.modifyLiquidity(key, TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), 0);
        assertGe(collected.amount0(), 0);
        assertGe(collected.amount1(), 0);
        assertEq(hook.latestBuyer(), alice);
        assertEq(hook.pot(), 0.02 ether);
        assertEq(hook.buyCount(), 1);
        assertBacked();
    }

    function test_malformedStateResponseDoesNotBreakBuysOrSells() public {
        buy(alice, 1 ether);
        vm.mockCall(address(core), abi.encodeCall(ISqueekCore.state, ()), hex"01");
        buy(bob, 1 ether);
        sell(carol, 1 ether);
        assertEq(hook.lastSeenFrontier(), 649, "bad return data cannot invent a frontier");
        assertEq(hook.latestBuyer(), bob);
        vm.expectRevert();
        hook.settleNaps(1);
        assertEq(hook.scanRound(), 650);
        assertEq(hook.pot(), 0.04 ether);
        vm.clearMockedCalls();
        core.setPaused(true);
        assertEq(hook.settleNaps(1), 0);
        assertBacked();
    }

    // ------------------------------------------------ settled findings: partial fills and the failsafe clock

    /// @dev Partial fills in the last second before the nap: exact-input and exact-output dust that
    /// offered far more than 0.001 ETH cannot displace Alice; a real partial fill in the first second
    /// of the nap qualifies but only for the next game.
    function test_partialFillsAroundTheBoundaryFollowExecutedEth() public {
        vm.warp(roundStart(651) - 1);
        buy(alice, 1 ether);
        uint160 price = currentSqrtPrice();
        BalanceDelta carolDelta = buyWithLimit(carol, -int256(1 ether), price - price / 1e13);
        uint256 carolPoolEth = uint256(uint128(-carolDelta.amount0())) - 0.02 ether;
        uint256 carolFee = carolPoolEth * 200 / 9800;
        assertLt(carolPoolEth + carolFee, 0.001 ether, "Carol's fill is dust");
        assertGt(carolFee, 0);
        assertEq(hook.owed(carol), 0.02 ether - carolFee);
        price = currentSqrtPrice();
        BalanceDelta daveDelta = buyWithLimit(dave, int256(1_000 ether), price - price / 1e13);
        uint256 daveGross = uint256(uint128(-daveDelta.amount0()));
        assertLt(daveGross, 0.001 ether, "Dave's exact-output fill is dust");
        assertEq(hook.owed(dave), 0, "exact output reserves nothing");
        assertEq(hook.latestBuyer(), alice);
        uint256 firstPot = 0.02 ether + carolFee + daveGross / 50;
        assertEq(hook.cumulativeFees(), firstPot);

        warpToRound(651);
        price = currentSqrtPrice();
        BalanceDelta bobDelta = buyWithLimit(bob, -int256(10 ether), price - price / 1e6);
        uint256 bobPoolEth = uint256(uint128(-bobDelta.amount0())) - 0.2 ether;
        uint256 bobFee = bobPoolEth * 200 / 9800;
        assertLt(bobPoolEth + bobFee, 10 ether, "partial");
        assertGe(bobPoolEth + bobFee, 0.001 ether, "but large enough to qualify");
        assertEq(hook.latestBuyer(), bob);
        assertEq(hook.owed(bob), 0.2 ether - bobFee);

        core.setWork(650, 1);
        core.setFrontier(653);
        warpToRound(654);
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, firstPot, "fees before round 651 only");
        assertEq(hook.pot(), bobFee, "Bob's fee waits for the next game");
        assertEq(hook.totalOwed(), 0.02 ether - carolFee + 0.2 ether - bobFee, "refunds are not pot");
        assertBacked();
        vm.prank(carol);
        hook.withdrawOwed();
        vm.prank(bob);
        hook.withdrawOwed();
        assertEq(carol.balance + bob.balance, 0.22 ether - carolFee - bobFee);
        assertEq(hook.totalOwed(), 0);
        assertBacked();
    }

    /// @dev A sender wallet with code that rejects ETH keeps its refund as a debt and blocks nobody.
    function test_partialRefundToRejectingOriginIsHeldAndDoesNotBlockNap() public {
        RejectingWinner origin = new RejectingWinner();
        buy(alice, 1 ether);
        uint160 price = currentSqrtPrice();
        buyWithLimit(address(origin), -int256(1 ether), price - price / 1e13);
        uint256 refund = hook.owed(address(origin));
        assertGt(refund, 0.019 ether);
        assertEq(hook.latestBuyer(), alice);
        vm.expectRevert(HamsterNap3D.TransferFailed.selector);
        origin.withdrawFrom(address(hook));
        core.setWork(650, 1);
        core.setFrontier(653);
        warpToRound(654);
        uint256 pot = hook.pot();
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, pot);
        assertEq(hook.owed(address(origin)), refund, "the nap payout cannot spend a refund");
        assertBacked();
        origin.setAccepting(true);
        origin.withdrawFrom(address(hook));
        assertEq(address(origin).balance, refund);
        assertBacked();
    }

    /// @dev Settlement lag: a backlog of old rounds certified eight days late is a fresh advance.
    /// A claim call records the sighting; the failsafe opens exactly seven unchanged days later.
    function test_lateBacklogSeenByClaimRestartsFailsafeClock() public {
        buy(alice, 1 ether);
        uint256 firstOpen = hook.failsafeOpensAt();
        assertEq(firstOpen, block.timestamp + 7 days);
        vm.warp(block.timestamp + 8 days);
        core.setWork(650, 1);
        core.setWork(652, 1);
        core.setFrontier(660);
        assertEq(hook.settleNaps(1), 1, "nap 653..655 found in the backlog");
        assertEq(alice.balance, 0.02 ether);
        buy(bob, 2 ether);
        uint256 opensAt = block.timestamp + 7 days;
        assertEq(hook.frontierSeenAt(), block.timestamp);
        assertEq(hook.failsafeOpensAt(), opensAt);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, opensAt));
        hook.failsafe();
        // The core stalls and starts reverting: the last sighting still dates the failsafe.
        core.setReverting(true);
        vm.warp(opensAt - 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, opensAt));
        hook.failsafe();
        vm.warp(opensAt);
        vm.expectEmit(true, false, false, true, address(hook));
        emit HamsterNap3D.FailsafeTaken(bob, 0.04 ether, 660);
        hook.failsafe();
        assertEq(bob.balance, 0.04 ether);
        assertEq(alice.balance, 0.02 ether, "the settled nap is not paid again");
        assertBacked();
    }

    /// @dev A sell observes nothing, so it cannot keep the failsafe shut; a dust buy does.
    function test_onlyBuysAndClaimsMoveFailsafeClock() public {
        buy(alice, 1 ether);
        uint256 opensAt = hook.failsafeOpensAt();
        vm.warp(opensAt - 1 days);
        core.setFrontier(650);
        sell(carol, 1 ether);
        assertEq(hook.failsafeOpensAt(), opensAt, "a sell never reads the core");
        buy(dave, 49); // zero fee, not qualifying, but it does read the core
        assertEq(hook.buyCount(), 1, "nothing recorded for a zero-fee dust buy");
        assertEq(hook.failsafeOpensAt(), block.timestamp + 7 days);
        assertEq(hook.latestBuyer(), alice);
    }

    /// @dev Page one of the backlog is readable and holds a certified nap; page two reverts. The failsafe
    /// pays that nap to its own winner, then the rest of the pot to the failsafe winner, and a later
    /// recovery of the core cannot pay either share again.
    function test_failsafeOverPartlyReadableBacklogPaysCertifiedNapToItsWinner() public {
        buy(alice, 1 ether);
        core.setWork(650, 1);
        core.setFrontier(680);
        warpToRound(681);
        buy(bob, 2 ether); // after the nap 651..653; observes frontier 680
        bytes memory pageTwo = abi.encodeCall(ISqueekCore.roundPage, (665, 680, 16));
        vm.mockCallRevert(address(core), pageTwo, abi.encodeWithSelector(MockSqueekCore.Reverting.selector));
        uint256 opensAt = hook.failsafeOpensAt();
        assertEq(opensAt, block.timestamp + 7 days);
        vm.warp(opensAt - 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, opensAt));
        hook.failsafe();
        vm.warp(opensAt);
        vm.expectEmit(true, true, false, true, address(hook));
        emit HamsterNap3D.NapSettled(651, alice, 0.02 ether);
        vm.expectEmit(true, false, false, true, address(hook));
        emit HamsterNap3D.FailsafeTaken(bob, 0.04 ether, 680);
        vm.prank(carol);
        hook.failsafe();
        assertEq(alice.balance, 0.02 ether, "the certified nap's pot went to its own winner");
        assertEq(bob.balance, 0.04 ether);
        assertEq(hook.scanRound(), 666, "the scan stopped at the unreadable page");
        assertEq(hook.pot(), 0);
        vm.clearMockedCalls();
        assertEq(hook.settleNaps(10), 0, "a zero run already counted is not a second nap");
        assertEq(hook.scanRound(), 681);
        assertEq(alice.balance + bob.balance, hook.cumulativeFees());
        assertBacked();
    }

    /// @dev The failsafe's cutoff is the later of its opening and seven days ago. A qualifying buy one
    /// second before the opening counts at the opening; a buy at the opening or later pays into the pot,
    /// wins nothing when placed in front of the call, and is paid its own fee, and only that, to the
    /// buyer once it is more than seven days old with the core still dead. Nobody is paid twice.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_failsafeWinnerBoundary(uint32 earlySeed, uint32 lateSeed, uint96 lateEthSeed) public {
        buy(alice, 1 ether);
        core.setReverting(true); // dead core: the clock stays at the game's last sighting
        uint256 opensAt = hook.failsafeOpensAt();
        uint256 early = bound(earlySeed, 1, 7 days - 1);
        uint256 late = bound(lateSeed, 0, 3 days);
        uint256 lateEth = bound(lateEthSeed, 0.001 ether, 5 ether);
        vm.warp(opensAt - early);
        buy(bob, 0.001 ether);
        vm.warp(opensAt - 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, opensAt));
        hook.failsafe();
        vm.warp(opensAt + late);
        uint256 lateAt = block.timestamp;
        buy(dave, lateEth);
        assertEq(hook.failsafeOpensAt(), opensAt, "a buy that reads nothing cannot move the clock");
        uint256 early_ = fee(1 ether) + fee(0.001 ether);
        (address winner, uint256 amount) = hook.failsafeWinner();
        assertEq(winner, bob);
        assertEq(amount, early_);
        hook.failsafe();
        assertEq(bob.balance, early_);
        assertEq(dave.balance, 0, "a buy in front of the call takes nothing");
        assertEq(hook.pot(), fee(lateEth), "the late fee waits in the pot");
        vm.expectRevert(HamsterNap3D.NothingToPay.selector);
        hook.failsafe();
        // Exactly seven days after the late buy it is not yet strictly before the cutoff.
        vm.warp(lateAt + 7 days);
        (winner, amount) = hook.failsafeWinner();
        assertEq(amount, 0);
        vm.expectRevert(HamsterNap3D.NothingToPay.selector);
        hook.failsafe();
        vm.warp(lateAt + 7 days + 1);
        (winner, amount) = hook.failsafeWinner();
        assertEq(winner, dave);
        assertEq(amount, fee(lateEth));
        vm.prank(carol);
        hook.failsafe();
        assertEq(dave.balance, fee(lateEth));
        assertEq(bob.balance, early_, "the earlier winner is not paid again");
        assertEq(hook.pot(), 0);
        assertEq(hook.cumulativePaid(), hook.cumulativeFees());
        assertBacked();
    }

    /// @dev Settled finding (failsafe frozen at the first opening), case 2: a game opened by a dust buy
    /// has no qualifying buyer at the opening. A qualifying buy after the opening is paid the whole pot,
    /// the dust fee included, once it is more than seven days old; before that the call refuses.
    function test_failsafeOpenedByDustPaysLaterQualifyingBuyerAfterSevenDays() public {
        buy(alice, 0.0005 ether);
        core.setReverting(true);
        uint256 opensAt = hook.failsafeOpensAt();
        vm.warp(opensAt + 1);
        vm.expectRevert(HamsterNap3D.NoQualifyingBuyer.selector);
        hook.failsafe();
        buy(bob, 1 ether);
        uint256 boughtAt = block.timestamp;
        vm.warp(boughtAt + 7 days);
        vm.expectRevert(HamsterNap3D.NoQualifyingBuyer.selector);
        hook.failsafe();
        vm.warp(boughtAt + 7 days + 1);
        hook.failsafe();
        assertEq(bob.balance, fee(0.0005 ether) + fee(1 ether));
        assertEq(alice.balance, 0, "a dust buyer never qualifies");
        assertEq(hook.pot(), 0);
        assertBacked();
    }

    /// @dev A dust buy after the cutoff's last qualifying buy is paid to that buyer once it ages too: the
    /// dust buyer cannot take the position, and its fee is not locked.
    function test_failsafeDustFeeAfterPayoutReachesLastQualifyingBuyer() public {
        buy(alice, 1 ether);
        core.setReverting(true);
        vm.warp(hook.failsafeOpensAt());
        hook.failsafe();
        assertEq(alice.balance, fee(1 ether));
        buy(carol, 0.0005 ether);
        uint256 dustAt = block.timestamp;
        vm.warp(dustAt + 7 days + 1);
        (address winner, uint256 amount) = hook.failsafeWinner();
        assertEq(winner, alice);
        assertEq(amount, fee(0.0005 ether));
        hook.failsafe();
        assertEq(alice.balance, fee(1 ether) + fee(0.0005 ether));
        assertEq(carol.balance, 0);
        assertEq(hook.pot(), 0);
        assertBacked();
    }
}
