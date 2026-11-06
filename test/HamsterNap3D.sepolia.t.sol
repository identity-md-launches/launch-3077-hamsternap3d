// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {HamsterNap3D} from "../src/HamsterNap3D.sol";
import {ISqueekCore} from "../src/interfaces/ISqueekCore.sol";
import {SepoliaRounds} from "./fixtures/SepoliaRounds.sol";

/// @notice The game replayed over the real round pages captured from the live Sepolia core.
contract HamsterNap3DSepoliaTest is HookTestBase {
    function setUp() public override {
        super.setUp();
        seedBothSides(1_000_000 ether);
        SepoliaRounds.load(core);
    }

    function test_fixtureMatchesTheCapturedPages() public {
        ISqueekCore.CoreState memory s = core.state();
        assertEq(s.settledThroughRound, 642);
        assertEq(s.cumulativeWork, 55392);

        ISqueekCore.RoundPage memory page = core.roundPage(626, 642, 16);
        assertEq(page.certifiedThroughRound, 642);
        assertEq(page.start.cumulativeWork, 48276);
        assertEq(page.end.cumulativeWork, 55392);
        assertEq(page.rounds.length, 15, "round 640 had no work");
        assertEq(page.rounds[0].roundId, 627);
        assertEq(page.rounds[0].cumulativeWork, 48704);
        assertEq(page.rounds[13].roundId, 641);
        assertEq(page.rounds[14].roundId, 642);

        page = core.roundPage(530, 546, 16);
        assertEq(page.rounds.length, 1);
        assertEq(page.rounds[0].roundId, 539);
        assertEq(page.rounds[0].cumulativeWork, 45957);

        page = core.roundPage(546, 562, 16);
        assertEq(page.rounds.length, 0);
        assertEq(page.start.cumulativeWork, 45957);

        // The documented error cases.
        vm.expectRevert(ISqueekCore.InvalidRoundPageBounds.selector);
        core.roundPage(610, 600, 16);
        vm.expectRevert(ISqueekCore.InvalidRoundPageBounds.selector);
        core.roundPage(640, 700, 16);
        vm.expectRevert(ISqueekCore.InvalidRoundPageBounds.selector);
        core.roundPage(600, 620, 17);
    }

    function test_replayFindsTheThreeRealNapsAndPaysInOrder() public {
        // The pool's first swap in round 483, then buys across the day.
        warpToRound(483);
        buy(alice, 1 ether);
        warpToRound(500);
        buy(bob, 2 ether); // last qualifying buy before the nap at 503
        warpToRound(510);
        buy(carol, 4 ether); // during the nap at 503: counts for the next game, won at 519
        warpToRound(539);
        buy(dave, 8 ether); // the single worked round between two naps; wins the nap at 540
        vm.warp(roundStart(643) + 10);

        vm.expectEmit(true, true, false, true);
        emit HamsterNap3D.NapSettled(503, bob, fee(3 ether));
        vm.expectEmit(true, true, false, true);
        emit HamsterNap3D.NapSettled(519, carol, fee(4 ether));
        vm.expectEmit(true, true, false, true);
        emit HamsterNap3D.NapSettled(540, dave, fee(8 ether));
        uint256 settled = hook.settleNaps(20);
        assertEq(settled, 3);
        assertEq(hook.napsSettled(), 3);
        assertEq(bob.balance, fee(3 ether));
        assertEq(carol.balance, fee(4 ether));
        assertEq(dave.balance, fee(8 ether));
        assertEq(hook.pot(), 0);
        assertEq(hook.scanRound(), 643);
        assertEq(hook.zeroRun(), 0, "642 had work");
        assertBacked();
    }

    function test_singleZeroWorkRoundsAreNotNaps() public {
        // Start after the long sleep: rounds 622..642 have one zero-work round, 640.
        warpToRound(622);
        buy(alice, 1 ether);
        vm.warp(roundStart(643) + 10);
        assertEq(hook.settleNaps(20), 0);
        assertEq(hook.napsSettled(), 0);
        assertEq(hook.pot(), fee(1 ether));
        assertEq(hook.scanRound(), 643);
    }

    function test_replayScansPageByPage() public {
        warpToRound(483);
        buy(alice, 1 ether);
        vm.warp(roundStart(643) + 10);
        uint256 total;
        uint256 calls;
        while (hook.scanRound() <= 642) {
            total += hook.settleNaps(1);
            calls++;
        }
        assertEq(calls, 10, "160 rounds in pages of 16");
        assertEq(total, 3);
        assertEq(alice.balance, fee(1 ether), "alice wins the first nap, the later ones have no new fees");
    }

    function test_failsafeAgainstTheCapturedFrontier() public {
        warpToRound(643);
        buy(alice, 1 ether);
        assertEq(hook.lastSeenFrontier(), 642);
        // The buy, which first saw frontier 642, happened in the first second after round 642 ended.
        uint256 opensAt = roundEnd(642) + 7 days;
        assertEq(hook.failsafeOpensAt(), opensAt);
        vm.warp(opensAt - 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, opensAt));
        hook.failsafe();
        vm.warp(opensAt);
        hook.failsafe();
        assertEq(alice.balance, fee(1 ether));
    }
}
