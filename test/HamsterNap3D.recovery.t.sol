// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {HamsterNap3D} from "../src/HamsterNap3D.sol";
import {ISqueekCore} from "../src/interfaces/ISqueekCore.sol";
import {MockSqueekCore} from "./mocks/MockSqueekCore.sol";

/// @notice Recovery from a core that half works: `state()` unreadable while `roundPage` answers,
/// `roundPage` unreadable while `state()` keeps advancing, a reported frontier for a round that has
/// not ended, and a replacement core whose timeline is ahead of the clock.
contract HamsterNap3DRecoveryTest is HookTestBase {
    MockSqueekCore internal replacement;

    function setUp() public override {
        super.setUp();
        seedBothSides(1_000_000 ether);
        core.setFrontier(649);
        replacement = new MockSqueekCore();
    }

    // ---------------------------------------------------------------- state() unreadable, pages readable

    /// A nap the hook saw certified stays payable through `roundPage` after `state()` breaks.
    function test_settleNapsScansThroughLastSeenFrontierWhenStateIsUnreadable() public {
        buy(alice, 1 ether); // round 650: alice is the last buyer before the nap at 651
        core.setWork(650, 1);
        core.setFrontier(653);
        vm.warp(roundEnd(653));
        buy(bob, 0.5 ether); // observes frontier 653
        assertEq(hook.lastSeenFrontier(), 653);
        core.setReadFailures(true, false, false);

        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, fee(1 ether));
        assertEq(hook.scanRound(), 654);
        assertEq(hook.pot(), fee(0.5 ether));
        assertBacked();
        // Nothing the hook saw certified is left: the dead state() is reported, as before.
        vm.expectRevert(HamsterNap3D.CoreUnreadable.selector);
        hook.settleNaps(1);
        // A page that cannot be read still reverts the claim.
        core.setFrontier(670);
        vm.warp(roundEnd(670));
        buy(carol, 0.001 ether);
        core.setReadFailures(true, false, true);
        vm.expectRevert(HamsterNap3D.CoreUnreadable.selector);
        hook.settleNaps(1);
    }

    /// The reviewer's case: more than eight pages the hook saw certified, then `state()` breaks.
    /// The failsafe refuses over the backlog; `settleNaps` works through it and pays the nap to its
    /// own winner; the failsafe then pays what is left.
    function test_longCertifiedBacklogIsPaidAfterStateBreaks() public {
        buy(alice, 1 ether);
        core.setWork(650, 1);
        sleepThrough(651, 849); // one nap, at 651, inside 13 pages
        vm.warp(roundEnd(849));
        buy(bob, 0.5 ether);
        assertEq(hook.lastSeenFrontier(), 849);
        assertEq(hook.scanRound(), 650);
        core.setReadFailures(true, false, false);

        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.NapsUnsettled.selector, uint64(650 + 8 * 16), uint64(849)));
        hook.failsafe();
        assertEq(hook.scanRound(), 650, "the refused failsafe kept no progress");
        assertEq(hook.settleNaps(100), 1);
        assertEq(alice.balance, fee(1 ether), "the certified nap went to its winner");
        assertEq(hook.scanRound(), 850);
        hook.failsafe();
        assertEq(bob.balance, fee(0.5 ether), "the failsafe paid the rest");
        assertEq(hook.pot(), 0);
        assertBacked();
    }

    /// `setCore` cannot drop a nap the hook saw certified while its page still reads, whatever
    /// `state()` does; once settled, or when the page is unreadable too, the switch goes ahead.
    function test_setCoreHonoursLastSeenFrontierWhenStateIsUnreadable() public {
        buy(alice, 1 ether);
        core.setWork(650, 1);
        core.setFrontier(653);
        vm.warp(roundEnd(653));
        buy(bob, 0.0001 ether); // observes 653
        core.setReadFailures(true, false, false);
        replacement.setConfiguration(uint64(block.timestamp - 7 * 120), 120);
        replacement.setFrontier(7);

        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.NapsUnsettled.selector, uint64(650), uint64(653)));
        vm.prank(owner);
        hook.setCore(replacement);
        assertEq(address(hook.core()), address(core));

        uint256 snapshot = vm.snapshotState();
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, fee(1 ether));
        vm.prank(owner);
        hook.setCore(replacement);
        assertEq(address(hook.core()), address(replacement));

        // With the page unreadable as well nothing can be verified, and the backlog is dropped.
        vm.revertToState(snapshot);
        core.setReadFailures(true, false, true);
        vm.prank(owner);
        hook.setCore(replacement);
        assertEq(address(hook.core()), address(replacement));
        assertEq(alice.balance, 0);
        assertEq(hook.pot(), fee(1.0001 ether));
        assertBacked();
    }

    // ---------------------------------------------------------------- pages unreadable, frontier advancing

    /// The reviewer's case: after `finalizeCore` the pages break while `state()` keeps advancing.
    /// The failsafe call that finds this records it and returns; seven days later it pays.
    function test_failsafeRecordsPageFailureAndOpensSevenDaysLater() public {
        buy(alice, 1 ether);
        vm.prank(owner);
        hook.finalizeCore();
        core.setReadFailures(false, false, true);

        vm.warp(block.timestamp + 1 days);
        core.setFrontier(hook.currentRound() - 1);
        vm.expectRevert(HamsterNap3D.CoreUnreadable.selector);
        hook.settleNaps(8);
        uint256 noticedAt = block.timestamp;
        uint64 frontier = core.frontier();
        vm.expectEmit(false, false, false, true, address(hook));
        emit HamsterNap3D.PageFailureSeen(650, frontier, noticedAt + 7 days);
        hook.failsafe(); // shut, frontier readable, next page not: recorded, no payout, no revert
        assertEq(hook.pageFailureSeenAt(), noticedAt);
        assertEq(hook.lastSeenFrontier(), frontier, "the recording call keeps its sighting");
        assertEq(hook.failsafeOpensAt(), noticedAt + 7 days);
        assertEq(hook.cumulativePaid(), 0);

        for (uint256 d = 2; d <= 7; d++) {
            vm.warp(noticedAt + (d - 1) * 1 days);
            core.setFrontier(hook.currentRound() - 1);
            vm.expectRevert(HamsterNap3D.CoreUnreadable.selector);
            hook.settleNaps(8);
            vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, noticedAt + 7 days));
            hook.failsafe();
        }
        vm.warp(noticedAt + 7 days);
        core.setFrontier(hook.currentRound() - 1);
        vm.expectEmit(true, false, false, false, address(hook));
        emit HamsterNap3D.FailsafeTaken(alice, fee(1 ether), 0);
        hook.failsafe();
        assertEq(alice.balance, fee(1 ether));
        assertEq(hook.napsSettled(), 0);
        assertEq(hook.pot(), 0);
        assertBacked();
    }

    /// A page read by any scan clears the record, and the failsafe's own scan at the page clock's
    /// opening finds a recovered core, clears it and stays shut.
    function test_readablePageClearsRecordedPageFailure() public {
        buy(alice, 1 ether);
        core.setReadFailures(false, false, true);
        vm.warp(roundEnd(660));
        core.setFrontier(660);
        hook.failsafe(); // records
        uint256 noticedAt = block.timestamp;
        assertEq(hook.pageFailureSeenAt(), noticedAt);
        assertEq(hook.failsafeOpensAt(), noticedAt + 7 days);
        // A second call changes nothing and reports the recorded opening.
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, noticedAt + 7 days));
        hook.failsafe();

        uint256 snapshot = vm.snapshotState();
        core.setReadFailures(false, false, false);
        // Rounds 650..660 slept: one nap at 650, which alice's buy during round 650 does not win.
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, 0);
        assertEq(hook.pageFailureSeenAt(), 0, "a readable page clears the record");
        assertEq(hook.failsafeOpensAt(), noticedAt + 7 days, "the frontier clock alone remains");
        core.setFrontier(661);
        vm.warp(roundEnd(661));
        buy(bob, 0.001 ether);
        assertEq(hook.failsafeOpensAt(), block.timestamp + 7 days);

        // Pages recover only at the page clock's opening: the failsafe's scan clears the record and
        // the fresh advance it sees keeps it shut; its progress rolls back with the revert.
        vm.revertToState(snapshot);
        vm.warp(noticedAt + 7 days);
        core.setFrontier(hook.currentRound() - 1);
        core.setReadFailures(false, false, false);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, block.timestamp + 7 days));
        hook.failsafe();
        assertEq(hook.scanRound(), 650);
        assertEq(hook.pageFailureSeenAt(), noticedAt, "the reverted call kept nothing");
        assertEq(hook.settleNaps(100), 1);
        assertEq(hook.pageFailureSeenAt(), 0);
        assertEq(alice.balance, 0, "the nap at 650 has no winner before it");
        assertEq(hook.pot(), fee(1 ether));
        assertBacked();
    }

    /// Only a readable frontier with an unreadable page is recorded: a dead core is the frontier
    /// clock's case, and a readable next page is `settleNaps`'s.
    function test_failsafeRecordsNothingForDeadCoreOrReadableNextPage() public {
        buy(alice, 1 ether);
        core.setWork(650, 1);
        core.setFrontier(680);
        vm.warp(roundEnd(680));
        buy(bob, 0.001 ether); // observes 680: a backlog of two pages
        uint256 opensAt = block.timestamp + 7 days;

        core.setReverting(true);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, opensAt));
        hook.failsafe();
        assertEq(hook.pageFailureSeenAt(), 0, "a dead core is dated by the frontier clock");
        core.setReverting(false);

        // Page one reads and page two does not: the shut failsafe probes page one only.
        bytes memory pageTwo = abi.encodeCall(ISqueekCore.roundPage, (665, 680, 16));
        vm.mockCallRevert(address(core), pageTwo, abi.encodeWithSelector(MockSqueekCore.Reverting.selector));
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, opensAt));
        hook.failsafe();
        assertEq(hook.pageFailureSeenAt(), 0);
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, fee(1 ether));
        assertEq(hook.scanRound(), 666);
        // Now the next page is the unreadable one: recorded.
        uint256 noticedAt = block.timestamp;
        hook.failsafe();
        assertEq(hook.pageFailureSeenAt(), noticedAt);
        assertEq(hook.failsafeOpensAt(), opensAt, "the frontier clock, dated earlier, still decides");
        assertBacked();
    }

    /// With the frontier clock open, a readable prefix is settled and the later unreadable page is
    /// recorded in the same paying call.
    function test_openFailsafeRecordsLaterPageFailureBehindReadablePrefix() public {
        buy(alice, 1 ether);
        core.setWork(650, 1);
        core.setFrontier(680);
        vm.warp(roundEnd(680));
        buy(bob, 2 ether);
        bytes memory pageTwo = abi.encodeCall(ISqueekCore.roundPage, (665, 680, 16));
        vm.mockCallRevert(address(core), pageTwo, abi.encodeWithSelector(MockSqueekCore.Reverting.selector));
        vm.warp(hook.failsafeOpensAt());
        hook.failsafe();
        assertEq(alice.balance, fee(1 ether));
        assertEq(bob.balance, fee(2 ether));
        assertEq(hook.scanRound(), 666);
        assertEq(hook.pageFailureSeenAt(), block.timestamp);
        assertBacked();
    }

    // ---------------------------------------------------------------- frontiers that cannot be true

    /// A frontier at or past the running round is ignored, not clamped; the same value is accepted
    /// the second its round ends.
    function test_frontierForUnfinishedRoundIsIgnored() public {
        uint256 seenAt = block.timestamp;
        buy(alice, 1 ether); // sees 649
        assertEq(hook.lastSeenFrontier(), 649);
        core.setFrontier(650); // the running round
        vm.warp(roundEnd(650) - 1);
        buy(bob, 0.001 ether);
        assertEq(hook.lastSeenFrontier(), 649, "round 650 has not ended");
        assertEq(hook.frontierSeenAt(), seenAt);
        assertEq(hook.failsafeOpensAt(), seenAt + 7 days);
        core.setFrontier(100_650);
        buy(carol, 0.001 ether);
        assertEq(hook.lastSeenFrontier(), 649, "a frontier far in the future is not evidence");
        assertEq(hook.frontierSeenAt(), seenAt);
        vm.warp(roundEnd(650));
        core.setFrontier(650);
        vm.expectEmit(false, false, false, true, address(hook));
        emit HamsterNap3D.FrontierSeen(650);
        buy(dave, 0.001 ether);
        assertEq(hook.lastSeenFrontier(), 650);
        assertEq(hook.frontierSeenAt(), block.timestamp);
    }

    /// The reviewer's case: a core that misreports a frontier far ahead once and then stalls does
    /// not postpone the failsafe by years.
    function test_futureFrontierCannotPostponeFailsafe() public {
        uint256 seenAt = block.timestamp;
        buy(alice, 1 ether);
        vm.prank(owner);
        hook.finalizeCore();
        core.setReadFailures(false, false, true);
        core.setFrontier(650 + 100_000);
        buy(bob, 0.0001 ether);
        assertEq(hook.lastSeenFrontier(), 649);
        assertEq(hook.failsafeOpensAt(), seenAt + 7 days);
        vm.warp(seenAt + 8 days);
        vm.expectEmit(true, false, false, true, address(hook));
        emit HamsterNap3D.FailsafeTaken(alice, fee(1.0001 ether), 649);
        hook.failsafe();
        assertEq(alice.balance, fee(1.0001 ether));
        assertBacked();
    }

    /// A replacement core must already be running: its genesis and its frontier round's end are in
    /// the past, so a switch can never push the failsafe out. The boundary second is accepted.
    function test_setCoreRejectsTimelineAheadOfTheClock() public {
        buy(alice, 1 ether);
        address before = address(hook.core());

        replacement.setConfiguration(uint64(block.timestamp + 1), 120);
        vm.expectRevert(HamsterNap3D.InvalidGenesis.selector);
        vm.prank(owner);
        hook.setCore(replacement);

        replacement.setConfiguration(uint64(block.timestamp - 7 * 120 + 1), 120); // round 8 starts in 1 s
        replacement.setFrontier(7);
        vm.expectRevert(HamsterNap3D.InvalidCoreFrontier.selector);
        vm.prank(owner);
        hook.setCore(replacement);

        replacement.setConfiguration(uint64(block.timestamp + 36_500 days), 1);
        replacement.setFrontier(0);
        vm.expectRevert(HamsterNap3D.InvalidGenesis.selector);
        vm.prank(owner);
        hook.setCore(replacement);
        assertEq(address(hook.core()), before);
        assertEq(hook.GENESIS_TIMESTAMP(), GENESIS);
        assertEq(hook.ROUND_DURATION(), ROUND);

        replacement.setConfiguration(uint64(block.timestamp - 7 * 120), 120); // round 8 starts now
        replacement.setFrontier(7);
        vm.prank(owner);
        hook.setCore(replacement);
        assertEq(address(hook.core()), address(replacement));
        assertEq(hook.failsafeOpensAt(), block.timestamp + 7 days, "the seven days restart from the switch");

        // A new core at genesis with nothing settled: genesis now is the latest allowed.
        MockSqueekCore fresh = new MockSqueekCore();
        fresh.setConfiguration(uint64(block.timestamp), 600);
        vm.prank(owner);
        hook.setCore(fresh);
        assertEq(hook.scanRound(), 1);
        assertEq(hook.failsafeOpensAt(), block.timestamp + 7 days);
    }
}
