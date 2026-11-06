// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {HamsterNap3D} from "src/HamsterNap3D.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";
import {MockSqueekCore} from "./mocks/MockSqueekCore.sol";
import {RejectingWinner} from "./mocks/RejectingWinner.sol";

/// @notice Independent adversarial tests of the approved mutable-core workflow. Production
/// storage is never patched; migrations go through the owner's real entry points.
contract HamsterNap3DMigrationTest is HookTestBase {
    MockSqueekCore private next;

    function setUp() public override {
        super.setUp();
        vm.chainId(11155111);
        seedBothSides(1_000_000 ether);
        core.setFrontier(649);
        next = new MockSqueekCore();
        // A replacement timeline must already be running: genesis at the switch is the latest allowed.
        next.setConfiguration(uint64(vm.getBlockTimestamp()), 60);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ownerOriginNeverAuthorizesAnotherSender(address caller, bool lockFirst, bool finalize) public {
        vm.assume(caller != owner);
        buy(alice, 1 ether);
        if (lockFirst) {
            vm.prank(owner);
            hook.finalizeCore();
        }
        bytes32 beforeState = _snapshot();
        vm.expectRevert(HamsterNap3D.NotOwner.selector);
        vm.prank(caller, owner);
        if (finalize) hook.finalizeCore();
        else hook.setCore(next);
        assertEq(_snapshot(), beforeState, "unauthorized call changed game or funds");
    }

    function test_thirdZeroOnNextPageMustBePaidBeforeMigration() public {
        buy(alice, 1 ether);
        core.setWorkRange(650, 663, 1);
        core.setFrontier(666);
        vm.warp(roundEnd(666));
        assertEq(hook.settleNaps(1), 0);
        assertEq(hook.scanRound(), 666);
        assertEq(hook.zeroRun(), 2);
        bytes32 beforeState = _snapshot();
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.NapsUnsettled.selector, uint64(666), uint64(666)));
        _switch(next);
        assertEq(_snapshot(), beforeState);
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, 0.02 ether);
        _switch(next);
        assertEq(hook.zeroRun(), 0);
        assertEq(hook.zeroRunStart(), 0);
        assertEq(hook.napsSettled(), 1);
        next.setFrontier(3);
        hook.settleNaps(1);
        assertEq(alice.balance, 0.02 ether, "a new timeline cannot pay the old fee twice");
        assertEq(hook.pot(), 0);
        assertBacked();
    }

    function test_finalizationWithPendingNapDoesNotPayItOrRestartClock() public {
        buy(alice, 1 ether);
        core.setWork(650, 1);
        core.setFrontier(653);
        vm.warp(roundEnd(653));
        uint256 opens = hook.failsafeOpensAt();
        uint256 observed = hook.frontierSeenAt();
        vm.expectEmit(true, false, false, true, address(hook));
        emit HamsterNap3D.CoreFinalized(address(core));
        vm.prank(owner);
        hook.finalizeCore();
        assertEq(hook.scanRound(), 650);
        assertEq(hook.napsSettled(), 0);
        assertEq(hook.pot(), 0.02 ether);
        assertEq(hook.failsafeOpensAt(), opens);
        assertEq(hook.frontierSeenAt(), observed);
        vm.expectRevert(HamsterNap3D.CoreIsFinalized.selector);
        _switch(next);
        vm.prank(carol);
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, 0.02 ether);
        assertTrue(hook.coreFinalized());
        assertBacked();
    }

    function test_finalizationWhenCoreIsUnreadableStillAllowsFailsafeAndSells() public {
        buy(alice, 1 ether);
        uint256 opening = hook.failsafeOpensAt();
        core.setReverting(true);
        vm.warp(opening - 1);
        vm.prank(owner);
        hook.finalizeCore();
        assertEq(hook.failsafeOpensAt(), opening);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, opening));
        hook.failsafe();
        assertGt(sell(bob, 0.001 ether).amount0(), 0);
        vm.warp(opening);
        vm.prank(carol);
        hook.failsafe();
        assertEq(alice.balance, 0.02 ether);
        assertEq(carol.balance, 0);
        vm.expectRevert(HamsterNap3D.CoreIsFinalized.selector);
        _switch(next);
        vm.expectRevert(HamsterNap3D.CoreIsFinalized.selector);
        vm.prank(owner);
        hook.finalizeCore();
        assertBacked();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_wrongNewResponseLengthIsAtomic(uint16 lengthSeed, bool stateResponse) public {
        buy(alice, 1 ether);
        uint256 length = bound(lengthSeed, 0, 1024);
        uint256 correctLength = stateResponse ? 256 : 352;
        if (length == correctLength) length++;
        bytes memory response = new bytes(length);
        bytes memory selector =
            stateResponse ? abi.encodeCall(ISqueekCore.state, ()) : abi.encodeCall(ISqueekCore.configuration, ());
        vm.mockCall(address(next), selector, response);
        _expectFailedSwitch(HamsterNap3D.CoreUnreadable.selector);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_dirtyHighBitsInNewTimingOrFrontierAreRejected(uint256 invalidWord, uint8 fieldSeed) public {
        buy(alice, 1 ether);
        invalidWord = bound(invalidWord, uint256(type(uint64).max) + 1, type(uint256).max);
        uint8 field = fieldSeed % 3;
        bytes memory response;
        bytes memory selector;
        uint256 offset;
        if (field == 2) {
            response = abi.encode(next.state());
            selector = abi.encodeCall(ISqueekCore.state, ());
            offset = 32;
        } else {
            response = abi.encode(next.configuration());
            selector = abi.encodeCall(ISqueekCore.configuration, ());
            offset = field == 0 ? 64 : 96;
        }
        assembly ("memory-safe") {
            mstore(add(response, offset), invalidWord)
        }
        vm.mockCall(address(next), selector, response);
        _expectFailedSwitch(HamsterNap3D.CoreUnreadable.selector);
    }

    function test_failedSwitchDoesNotRestartAnAlreadyOpenFailsafe() public {
        buy(alice, 1 ether);
        uint256 opening = hook.failsafeOpensAt();
        vm.warp(opening);
        next.setReadFailures(true, false, false);
        _expectFailedSwitch(HamsterNap3D.CoreUnreadable.selector);
        assertEq(hook.failsafeOpensAt(), opening);
        hook.failsafe();
        assertEq(alice.balance, 0.02 ether);
        assertEq(hook.pot(), 0);
        assertBacked();
    }

    function test_readableUnsettledOldNapTakesPrecedenceOverBadNewCore() public {
        buy(alice, 1 ether);
        core.setWork(650, 1);
        core.setFrontier(653);
        next.setReverting(true);
        bytes32 beforeState = _snapshot();
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.NapsUnsettled.selector, uint64(650), uint64(653)));
        _switch(next);
        assertEq(_snapshot(), beforeState);
        vm.warp(roundEnd(653));
        hook.settleNaps(1);
        _expectFailedSwitch(HamsterNap3D.CoreUnreadable.selector);
        next.setReverting(false);
        _switch(next);
        assertEq(alice.balance, 0.02 ether);
    }

    function test_oldStateAndPageFailIndependentlyAndFailedCandidateNeverDropsHistory() public {
        buy(alice, 1 ether);
        core.setWork(650, 1);
        core.setFrontier(653);
        vm.warp(roundEnd(653));
        core.setReadFailures(true, false, false);
        next.setConfiguration(GENESIS, 0);
        _expectFailedSwitch(HamsterNap3D.InvalidRoundDuration.selector);
        core.setReadFailures(false, false, true);
        _expectFailedSwitch(HamsterNap3D.InvalidRoundDuration.selector);
        core.setReadFailures(false, false, false);
        assertEq(hook.settleNaps(1), 1, "old certified nap still payable after both failed attempts");
        assertEq(alice.balance, 0.02 ether);
        assertBacked();
    }

    function test_unreadableOldCoreDropsOnlyItsScanAndPreservesExistingDebt() public {
        RejectingWinner receiver = new RejectingWinner();
        buy(address(receiver), 1 ether);
        core.setWork(650, 1);
        core.setFrontier(653);
        vm.warp(roundEnd(653));
        hook.settleNaps(1);
        buy(bob, 2 ether);
        core.setWork(654, 1);
        core.setFrontier(657);
        core.setReadFailures(false, false, true);
        vm.warp(vm.getBlockTimestamp() + 1); // Bob's buy strictly precedes the new genesis.
        next.setConfiguration(uint64(vm.getBlockTimestamp()), 31);
        _switch(next);
        assertEq(hook.napsSettled(), 1);
        assertEq(hook.owed(address(receiver)), 0.02 ether);
        assertEq(hook.pot(), 0.04 ether);
        next.setFrontier(3);
        vm.warp(hook.roundEnd(3));
        hook.settleNaps(1);
        assertEq(bob.balance, 0.04 ether);
        receiver.setAccepting(true);
        receiver.withdrawFrom(address(hook));
        assertEq(address(receiver).balance, 0.02 ether);
        assertEq(hook.totalOwed(), 0);
        assertBacked();
    }

    function test_historicalNapOnNewCoreIsNotImportedAndPartialOldRunIsNotJoined() public {
        buy(alice, 1 ether);
        core.setFrontier(651);
        vm.warp(roundEnd(651));
        hook.settleNaps(1);
        assertEq(hook.zeroRun(), 2);
        next.setConfiguration(uint64(vm.getBlockTimestamp() - 10 * 31), 31);
        next.setFrontier(10); // All ten historical rounds were zero: no historical award.
        _switch(next);
        assertEq(hook.scanRound(), 11);
        assertEq(hook.zeroRun(), 0);
        assertEq(hook.settleNaps(1), 0);
        next.setFrontier(12);
        vm.warp(hook.roundEnd(12));
        assertEq(hook.settleNaps(1), 0);
        assertEq(alice.balance, 0);
        next.setFrontier(13);
        vm.warp(hook.roundEnd(13));
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, 0.02 ether);
        assertBacked();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_twoMigrationsPreserveTimeEligibilityAndDust(
        uint16 durationSeed,
        uint96 earlySeed,
        uint96 middleSeed,
        uint96 dustSeed
    ) public {
        uint256 early = bound(earlySeed, 0.001 ether, 2 ether);
        uint256 middle = bound(middleSeed, 0.001 ether, 2 ether);
        uint256 dust = bound(dustSeed, 50, 0.001 ether - 1);
        uint64 duration = uint64(bound(durationSeed, 1, 3600));
        buy(alice, early);
        vm.warp(vm.getBlockTimestamp() + 1); // Alice's buy strictly precedes the new genesis.
        next.setConfiguration(uint64(vm.getBlockTimestamp()), duration);
        _switch(next);
        vm.warp(hook.roundStart(1));
        buy(bob, middle); // Exact boundary: excluded from this nap.
        next.setFrontier(3);
        vm.warp(hook.roundEnd(3));
        hook.settleNaps(1);
        assertEq(alice.balance, early / 50);
        assertEq(bob.balance, 0);
        MockSqueekCore third = new MockSqueekCore();
        buy(carol, dust); // Nonqualifying fee belongs to Bob's next eligible prize.
        uint64 carolRound = hook.roundAt(vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + 1);
        // Round 100 ends exactly at the switch: the latest frontier a running timeline may report.
        third.setConfiguration(uint64(vm.getBlockTimestamp() - 100 * 31), 31);
        third.setFrontier(100);
        _switch(third);
        assertEq(hook.roundStart(101), vm.getBlockTimestamp());
        buy(dave, 1 ether); // Exact boundary of the next nap: excluded from it.
        vm.prank(owner);
        hook.finalizeCore();
        third.setFrontier(103);
        vm.warp(hook.roundEnd(103));
        assertEq(hook.settleNaps(1), 1);
        assertEq(bob.balance, middle / 50 + dust / 50);
        assertEq(carol.balance, 0);
        assertEq(dave.balance, 0);
        assertEq(hook.pot(), 0.02 ether);
        third.setWork(104, 1);
        third.setFrontier(107);
        vm.warp(hook.roundEnd(107));
        assertEq(hook.settleNaps(1), 1);
        assertEq(dave.balance, 0.02 ether);
        assertEq(hook.buyAt(0).round, 650);
        assertEq(hook.buyAt(1).round, 1);
        assertEq(hook.buyAt(2).round, carolRound);
        assertEq(hook.buyAt(3).round, 101);
        assertEq(hook.buyCount(), 4);
        assertEq(hook.settleNaps(10), 0);
        assertEq(hook.pot(), 0);
        assertBacked();
    }

    function test_frontierProgressOnNewCoreRestartsClockAgainButFinalizeDoesNot() public {
        buy(alice, 1 ether);
        vm.warp(hook.failsafeOpensAt());
        next.setConfiguration(uint64(vm.getBlockTimestamp() - 60), 60);
        next.setFrontier(1);
        _switch(next);
        uint256 switchedAt = vm.getBlockTimestamp();
        vm.warp(switchedAt + 6 days);
        next.setWork(2, 1);
        next.setFrontier(2);
        buy(bob, 0.0001 ether); // A dust buy observes advancement without changing the winner.
        uint256 opening = switchedAt + 13 days;
        assertEq(hook.failsafeOpensAt(), opening);
        vm.prank(owner);
        hook.finalizeCore();
        assertEq(hook.failsafeOpensAt(), opening);
        vm.warp(switchedAt + 7 days);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, opening));
        hook.failsafe();
        vm.warp(opening);
        hook.failsafe();
        assertEq(alice.balance, 0.02 ether + 0.000002 ether);
        assertBacked();
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

    function _snapshot() private view returns (bytes32 digest) {
        digest = keccak256(
            abi.encode(
                hook.core(),
                hook.coreFinalized(),
                hook.owner(),
                hook.GENESIS_TIMESTAMP(),
                hook.ROUND_DURATION(),
                hook.scanRound(),
                hook.zeroRun(),
                hook.zeroRunStart(),
                hook.lastSeenFrontier(),
                hook.frontierSeenAt()
            )
        );
        digest = keccak256(
            abi.encode(
                digest,
                hook.latestBuyer(),
                hook.cumulativeFees(),
                hook.cumulativePaid(),
                hook.napsSettled(),
                hook.firstNapSettled(),
                hook.totalOwed(),
                hook.claimsHeld(),
                hook.buyCount(),
                address(hook).balance
            )
        );
        digest = keccak256(
            abi.encode(digest, manager.balanceOf(address(hook), 0), alice.balance, bob.balance, owner.balance)
        );
        for (uint256 i; i < hook.buyCount(); i++) {
            digest = keccak256(abi.encode(digest, hook.buyAt(i)));
        }
    }
}

contract HamsterNap3DMigrationClaimsTest is HookTestBase {
    function test_migrationPreservesClaimsAndPartialFillRefundSeparatelyFromPot() public {
        vm.chainId(11155111);
        seedTokensOnly(1_000_000 ether);
        core.setFrontier(649);
        buy(alice, 1 ether);
        assertEq(hook.claimsHeld(), 0.02 ether);
        uint160 limit = currentSqrtPrice() - 1;
        buyWithLimit(bob, -int256(10 ether), limit);
        uint256 refund = hook.owed(bob);
        uint256 pot = hook.pot();
        assertGt(refund, 0, "partial fill must create refundable debt");
        assertEq(hook.latestBuyer(), alice, "partial dust fill does not qualify");
        MockSqueekCore candidate = new MockSqueekCore();
        vm.warp(vm.getBlockTimestamp() + 1); // Alice's buy strictly precedes the new genesis.
        candidate.setConfiguration(uint64(vm.getBlockTimestamp()), 60);
        candidate.setReadFailures(true, false, false);
        vm.expectRevert(HamsterNap3D.CoreUnreadable.selector);
        vm.prank(owner);
        hook.setCore(candidate);
        assertEq(hook.claimsHeld(), 0.02 ether);
        assertEq(hook.pot(), pot);
        assertEq(hook.owed(bob), refund);
        candidate.setReadFailures(false, false, false);
        vm.expectEmit(true, true, false, true, address(hook));
        emit HamsterNap3D.CoreChanged(address(core), address(candidate));
        vm.prank(owner);
        hook.setCore(candidate);
        assertEq(hook.claimsHeld(), 0.02 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.02 ether);
        assertEq(hook.owed(bob), refund);
        assertEq(hook.pot(), pot);
        vm.prank(bob);
        hook.withdrawOwed();
        assertEq(bob.balance, refund);
        assertEq(hook.pot(), pot, "refund never spends the prize");
        candidate.setFrontier(3);
        vm.warp(hook.roundEnd(3));
        hook.settleNaps(1);
        assertEq(alice.balance, pot);
        assertEq(hook.totalOwed(), 0);
        assertEq(hook.claimsHeld(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertBacked();
    }
}
