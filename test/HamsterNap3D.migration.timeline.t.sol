// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {HamsterNap3D} from "src/HamsterNap3D.sol";
import {MockSqueekCore} from "./mocks/MockSqueekCore.sol";

/// @notice Independent tests of the replacement-timeline rules of `setCore` (a running genesis and an
/// ended frontier), the old-core fallback to the last credible frontier, and the page-failure
/// failsafe clock across a switch and after `finalizeCore`.
contract HamsterNap3DMigrationTimelineTest is HookTestBase {
    uint256 private constant DELAY = 7 days;
    MockSqueekCore private next;

    function setUp() public override {
        super.setUp();
        vm.chainId(11155111);
        seedBothSides(1_000_000 ether);
        core.setFrontier(649);
        next = new MockSqueekCore();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_futureGenesisIsRejectedAtomically(uint64 aheadSeed, uint16 durationSeed, bool withFrontier)
        public
    {
        buy(alice, 1 ether);
        uint256 ahead = bound(aheadSeed, 1, type(uint64).max - vm.getBlockTimestamp());
        next.setConfiguration(uint64(vm.getBlockTimestamp() + ahead), uint64(bound(durationSeed, 1, 3600)));
        if (withFrontier) next.setFrontier(1);
        _expectFailedSwitch(HamsterNap3D.InvalidGenesis.selector);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_onlyAnEndedFrontierIsAccepted(
        uint32 backSeed,
        uint32 durationSeed,
        uint64 frontierSeed,
        bool late
    ) public {
        buy(alice, 1 ether);
        uint256 back = bound(backSeed, 0, 400 days);
        uint256 duration = bound(durationSeed, 1, 30 days);
        uint256 genesis = vm.getBlockTimestamp() - back;
        uint256 lastEnded = back / duration; // The highest round whose end is not after now.
        uint256 frontier =
            late ? bound(frontierSeed, lastEnded + 1, type(uint64).max - 1) : bound(frontierSeed, 0, lastEnded);
        next.setConfiguration(uint64(genesis), uint64(duration));
        _reportFrontier(frontier); // The mock's own state() walks every round; report it directly.
        if (late) {
            _expectFailedSwitch(HamsterNap3D.InvalidCoreFrontier.selector);
            return;
        }
        _switch(next);
        assertEq(hook.scanRound(), frontier + 1);
        assertEq(hook.lastSeenFrontier(), frontier);
        assertLt(frontier, hook.currentRound(), "an accepted frontier's round has ended");
        assertEq(hook.frontierSeenAt(), vm.getBlockTimestamp());
        assertEq(hook.pageFailureSeenAt(), 0);
        // A running timeline delays the failsafe by exactly seven days from the switch, never more.
        assertEq(hook.failsafeOpensAt(), vm.getBlockTimestamp() + DELAY);
        assertEq(hook.pot(), 0.02 ether);
        assertBacked();
    }

    function test_frontierEndingExactlyNowIsTheBoundary() public {
        next.setConfiguration(uint64(vm.getBlockTimestamp() - 10 * 60), 60);
        next.setFrontier(11);
        _expectFailedSwitch(HamsterNap3D.InvalidCoreFrontier.selector);
        // uint64 max, reported directly: no running timeline has ended that round.
        _reportFrontier(type(uint64).max);
        _expectFailedSwitch(HamsterNap3D.InvalidCoreFrontier.selector);
        vm.clearMockedCalls();
        next.setFrontier(10);
        _switch(next);
        assertEq(hook.roundEnd(10), vm.getBlockTimestamp());
        assertEq(hook.currentRound(), 11);
        assertEq(hook.failsafeOpensAt(), vm.getBlockTimestamp() + DELAY);
    }

    function test_genesisAtTheSwitchIsAcceptedOneSecondLaterIsNot() public {
        next.setConfiguration(uint64(vm.getBlockTimestamp() + 1), 60);
        _expectFailedSwitch(HamsterNap3D.InvalidGenesis.selector);
        next.setConfiguration(uint64(vm.getBlockTimestamp()), 60);
        _switch(next);
        assertEq(hook.GENESIS_TIMESTAMP(), vm.getBlockTimestamp());
        assertEq(hook.scanRound(), 1);
    }

    /// @dev A broken `state()` alone must not drop a nap the hook saw certified while pages answer.
    function test_unreadableOldStateFallsBackToLastSeenFrontier() public {
        buy(alice, 1 ether);
        core.setWork(650, 1);
        core.setFrontier(653);
        vm.warp(roundEnd(653));
        buy(bob, 0.0001 ether); // Dust: observes the frontier without becoming the latest buyer.
        assertEq(hook.lastSeenFrontier(), 653);
        core.setReadFailures(true, false, false);
        next.setConfiguration(uint64(vm.getBlockTimestamp()), 60);
        bytes32 beforeState = _snapshot();
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.NapsUnsettled.selector, uint64(650), uint64(653)));
        _switch(next);
        assertEq(_snapshot(), beforeState);
        // settleNaps scans through the last seen frontier while state() still fails.
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, 0.02 ether);
        assertEq(hook.scanRound(), 654);
        vm.expectRevert(HamsterNap3D.CoreUnreadable.selector);
        hook.settleNaps(1); // Nothing seen is left and state() is still unreadable.
        _switch(next);
        assertEq(address(hook.core()), address(next));
        assertEq(hook.pot(), 0.000002 ether, "only the dust fee remains");
        assertBacked();
    }

    /// @dev Rounds certified after the last observation cannot be known without state(): they drop.
    function test_unreadableOldStateDropsOnlyUnseenRounds() public {
        buy(alice, 1 ether);
        core.setWork(650, 1);
        core.setFrontier(653);
        vm.warp(roundEnd(653));
        core.setReadFailures(true, false, false); // The hook never saw 653.
        assertEq(hook.lastSeenFrontier(), 649);
        next.setConfiguration(uint64(vm.getBlockTimestamp()), 60);
        _switch(next);
        assertEq(hook.napsSettled(), 0);
        assertEq(hook.pot(), 0.02 ether, "dropped history keeps the pot for the new core");
        next.setFrontier(3);
        vm.warp(hook.roundEnd(3));
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, 0.02 ether);
        assertBacked();
    }

    function test_oldStateAndPagesBothUnreadableDropsSeenHistory() public {
        buy(alice, 1 ether);
        core.setWork(650, 1);
        core.setFrontier(653);
        vm.warp(roundEnd(653));
        buy(bob, 0.0001 ether);
        core.setReverting(true);
        next.setConfiguration(uint64(vm.getBlockTimestamp()), 60);
        _switch(next);
        assertEq(hook.scanRound(), 1);
        assertEq(hook.napsSettled(), 0);
        assertEq(hook.pot(), 0.020002 ether);
        assertBacked();
    }

    function test_switchClearsAPageFailureAndRestartsTheClock() public {
        buy(alice, 1 ether);
        core.setWork(650, 1);
        core.setFrontier(653);
        vm.warp(roundEnd(653));
        core.setReadFailures(false, false, true);
        uint256 recordedAt = vm.getBlockTimestamp();
        vm.expectEmit(false, false, false, true, address(hook));
        emit HamsterNap3D.PageFailureSeen(650, 653, recordedAt + DELAY);
        hook.failsafe(); // Records instead of reverting.
        assertEq(hook.pageFailureSeenAt(), recordedAt);
        vm.warp(recordedAt + 3 days);
        next.setConfiguration(uint64(vm.getBlockTimestamp() - 120), 60);
        next.setFrontier(2);
        _switch(next);
        assertEq(hook.pageFailureSeenAt(), 0, "a switch clears the old core's page record");
        assertEq(hook.scanRound(), 3);
        assertEq(hook.failsafeOpensAt(), vm.getBlockTimestamp() + DELAY);
        vm.warp(recordedAt + DELAY);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, recordedAt + 3 days + DELAY));
        hook.failsafe();
        assertEq(hook.pot(), 0.02 ether);
        assertBacked();
    }

    /// @dev After finalization, a core that keeps advancing its frontier while no page can be read
    /// cannot keep the pot frozen: the failsafe opens seven days after the recorded page failure.
    function test_finalizedCoreAdvancingWithoutPagesCannotFreezeTheFailsafe() public {
        buy(alice, 1 ether);
        vm.prank(owner);
        hook.finalizeCore();
        core.setWork(650, 1);
        core.setFrontier(651);
        vm.warp(roundEnd(651));
        core.setReadFailures(false, false, true);
        uint256 recordedAt = vm.getBlockTimestamp();
        hook.failsafe();
        assertEq(hook.pageFailureSeenAt(), recordedAt);
        for (uint64 day = 1; day < 7; day++) {
            vm.warp(recordedAt + day * 1 days);
            core.setFrontier(hook.currentRound() - 1);
            buy(bob, 0.0001 ether); // Observes each advance: the frontier clock alone would never open.
            assertEq(hook.frontierSeenAt(), vm.getBlockTimestamp());
            assertEq(hook.failsafeOpensAt(), recordedAt + DELAY);
        }
        vm.warp(recordedAt + DELAY - 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, recordedAt + DELAY));
        hook.failsafe();
        vm.warp(recordedAt + DELAY);
        hook.failsafe();
        // Six dust fees precede the cutoff; Alice is still the latest qualifying buyer.
        assertEq(alice.balance, 0.02 ether + 6 * 0.000002 ether);
        assertTrue(hook.coreFinalized());
        assertBacked();
    }

    /// @dev Once switched in, the replacement core cannot push the failsafe out by reporting a
    /// frontier whose round is still running.
    function test_newCoreReportingAnUnendedFrontierIsIgnored() public {
        buy(alice, 1 ether);
        next.setConfiguration(uint64(vm.getBlockTimestamp()), 60);
        _switch(next);
        uint256 opening = hook.failsafeOpensAt();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        next.setFrontier(hook.currentRound());
        buy(bob, 0.0001 ether);
        assertEq(hook.lastSeenFrontier(), 0);
        assertEq(hook.failsafeOpensAt(), opening);
        vm.prank(owner);
        hook.finalizeCore();
        vm.warp(opening);
        next.setReverting(true);
        hook.failsafe();
        assertEq(alice.balance, 0.02 ether + 0.000002 ether);
        assertBacked();
    }

    function _reportFrontier(uint256 frontier) private {
        bytes memory response = abi.encode(next.state());
        assembly ("memory-safe") {
            mstore(add(response, 32), frontier)
        }
        vm.mockCall(address(next), abi.encodeWithSignature("state()"), response);
    }

    function _switch(MockSqueekCore candidate) private {
        vm.prank(owner);
        hook.setCore(candidate);
    }

    function _expectFailedSwitch(bytes4 reason) private {
        bytes32 beforeState = _snapshot();
        vm.expectRevert(reason);
        _switch(next);
        assertEq(_snapshot(), beforeState, "failed migration changed state or value");
        assertBacked();
    }

    function _snapshot() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    abi.encode(
                        hook.core(),
                        hook.GENESIS_TIMESTAMP(),
                        hook.ROUND_DURATION(),
                        hook.scanRound(),
                        hook.zeroRun(),
                        hook.zeroRunStart(),
                        hook.lastSeenFrontier(),
                        hook.frontierSeenAt(),
                        hook.pageFailureSeenAt()
                    )
                ),
                hook.cumulativeFees(),
                hook.cumulativePaid(),
                hook.napsSettled(),
                hook.totalOwed(),
                hook.claimsHeld(),
                hook.buyCount(),
                address(hook).balance
            )
        );
    }
}
