// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {HamsterNap3D} from "../src/HamsterNap3D.sol";
import {ISqueekCore} from "../src/interfaces/ISqueekCore.sol";
import {MockSqueekCore} from "./mocks/MockSqueekCore.sol";
import {RejectingWinner} from "./mocks/RejectingWinner.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract HamsterNap3DCoreTest is HookTestBase {
    MockSqueekCore internal replacement;
    /// @dev The first second of the replacement's round 8: its frontier round 7 has ended from here,
    /// so a switch to it is accepted. `_switch` moves the clock forward to it when needed.
    uint256 internal replacementReady;

    function setUp() public override {
        super.setUp();
        seedBothSides(1_000_000 ether);
        core.setFrontier(649);
        replacement = new MockSqueekCore();
        // A different timeline: the new core's round 8 starts 43 seconds after setUp.
        replacementReady = roundStart(650) + 60;
        replacement.setConfiguration(uint64(replacementReady - 7 * 120), 120);
        replacement.setFrontier(7);
    }

    function test_initialValuesAndOwnerAreExplicitWithoutConstructorReads() public {
        assertEq(address(hook.core()), 0xFD6C166D4B8E2962E65746a13e5a0797CD4dE0c4);
        assertEq(hook.GENESIS_TIMESTAMP(), 1793735400);
        assertEq(hook.ROUND_DURATION(), 600);
        assertEq(hook.owner(), owner);
        assertNotEq(hook.owner(), factory);
        assertNotEq(hook.owner(), address(this));
        assertFalse(hook.coreFinalized());
        // A dead dependency must not prevent factory construction, even on an empty chain.
        vm.etch(address(core), "");
        HamsterNap3D fresh = deployHook(manager, factory);
        assertEq(fresh.owner(), owner);
        assertEq(address(fresh.core()), address(core));
        assertEq(fresh.GENESIS_TIMESTAMP(), GENESIS);
    }

    function test_setCoreOnlyOwnerNotFactoryOrOwnerOrigin() public {
        bytes32 beforeState = _snapshot();
        vm.expectRevert(HamsterNap3D.NotOwner.selector);
        vm.prank(alice);
        hook.setCore(replacement);
        vm.expectRevert(HamsterNap3D.NotOwner.selector);
        vm.prank(factory);
        hook.setCore(replacement);
        vm.expectRevert(HamsterNap3D.NotOwner.selector);
        vm.prank(alice, owner);
        hook.setCore(replacement);
        assertEq(_snapshot(), beforeState);
        _switch();
        assertEq(address(hook.core()), address(replacement));
    }

    function test_constructorRejectsMissingOwner() public {
        vm.expectRevert(HamsterNap3D.InvalidOwner.selector);
        this.deployWithMissingOwner();
    }

    function deployWithMissingOwner() external {
        owner = address(0);
        deployHook(manager, factory);
    }

    function test_finalizeOnlyOwnerAndNoRepeat() public {
        vm.expectRevert(HamsterNap3D.NotOwner.selector);
        vm.prank(factory);
        hook.finalizeCore();
        vm.expectRevert(HamsterNap3D.NotOwner.selector);
        vm.prank(alice, owner);
        hook.finalizeCore();
        vm.expectEmit(true, false, false, true, address(hook));
        emit HamsterNap3D.CoreFinalized(address(core));
        vm.prank(owner);
        hook.finalizeCore();
        assertTrue(hook.coreFinalized());
        vm.expectRevert(HamsterNap3D.CoreIsFinalized.selector);
        vm.prank(owner);
        hook.finalizeCore();
        vm.expectRevert(HamsterNap3D.CoreIsFinalized.selector);
        vm.prank(owner);
        hook.setCore(replacement);
        assertEq(address(hook.core()), address(core));
    }

    function test_finalizeAfterSwitchFreezesChosenCoreAndTiming() public {
        _switch();
        bytes32 beforeState = _snapshot();
        vm.expectEmit(true, false, false, true, address(hook));
        emit HamsterNap3D.CoreFinalized(address(replacement));
        vm.prank(owner);
        hook.finalizeCore();
        replacement.setConfiguration(1, 1);
        vm.expectRevert(HamsterNap3D.CoreIsFinalized.selector);
        vm.prank(owner);
        hook.setCore(replacement);
        assertEq(_snapshot(), beforeState);
        assertTrue(hook.coreFinalized());
    }

    function test_switchBeforeFirstSwapUsesNewFrontierAndEmitsEvent() public {
        _readyReplacement();
        uint256 switchedAt = vm.getBlockTimestamp();
        assertEq(switchedAt, hook.GENESIS_TIMESTAMP() + 649 * 600 + 60, "round 650 of the old timing");
        vm.expectEmit(true, true, false, true, address(hook));
        emit HamsterNap3D.CoreChanged(address(core), address(replacement));
        _switch();
        assertEq(hook.scanRound(), 8);
        assertEq(hook.lastSeenFrontier(), 7);
        assertEq(hook.frontierSeenAt(), switchedAt);
        assertEq(hook.pageFailureSeenAt(), 0);
        assertEq(hook.failsafeOpensAt(), switchedAt + 7 days);
        assertEq(hook.zeroRun(), 0);
        assertEq(hook.zeroRunStart(), 0);
        assertEq(hook.ROUND_DURATION(), 120);
        assertEq(hook.GENESIS_TIMESTAMP(), replacement.configuration().genesisTimestamp);
        // The first swap must not overwrite the switch's scan baseline.
        vm.warp(hook.roundStart(12));
        sell(alice, 1 ether);
        assertEq(hook.scanRound(), 8);
        assertEq(hook.frontierSeenAt(), switchedAt);
    }

    function test_oldCertifiedNapMustBeSettledFirstAndIsNotPaidTwice() public {
        buy(alice, 1 ether);
        core.setWork(650, 1);
        core.setFrontier(653);
        vm.warp(roundEnd(653));
        buy(bob, 2 ether);
        bytes32 beforeState = _snapshot();
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.NapsUnsettled.selector, uint64(650), uint64(653)));
        _switch();
        assertEq(_snapshot(), beforeState);
        assertEq(alice.balance, 0);
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, 0.02 ether);
        assertEq(hook.pot(), 0.04 ether);
        _switch();
        assertEq(hook.napsSettled(), 1);
        assertTrue(hook.firstNapSettled());
        replacement.setFrontier(10);
        hook.settleNaps(1);
        // This new nap predates Bob's buy. Alice's fee was already paid on the old core.
        assertEq(alice.balance, 0.02 ether);
        assertEq(bob.balance, 0);
        assertEq(hook.pot(), 0.04 ether);
        assertBacked();
    }

    function test_readableBacklogRequiresAllPagesEvenWithoutNaps() public {
        buy(alice, 1 ether);
        workThrough(650, 690);
        vm.warp(roundEnd(690));
        hook.settleNaps(1);
        assertEq(hook.scanRound(), 666);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.NapsUnsettled.selector, uint64(666), uint64(690)));
        _switch();
        hook.settleNaps(2);
        _switch();
        assertEq(hook.pot(), 0.02 ether);
        assertEq(hook.napsSettled(), 0);
    }

    function test_switchClearsTwoZeroRunAndDoesNotImportNewCoreHistory() public {
        buy(alice, 1 ether);
        sleepThrough(650, 651);
        hook.settleNaps(1);
        assertEq(hook.zeroRun(), 2);
        assertEq(hook.zeroRunStart(), 650);
        _switch();
        assertEq(hook.zeroRun(), 0);
        assertEq(hook.zeroRunStart(), 0);
        replacement.setFrontier(9);
        vm.warp(hook.roundEnd(9));
        assertEq(hook.settleNaps(1), 0);
        assertEq(hook.zeroRun(), 2);
        assertEq(hook.zeroRunStart(), 8);
        replacement.setFrontier(10);
        vm.warp(hook.roundEnd(10));
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, 0.02 ether);
        assertBacked();
    }

    function test_unreadableOldStateDropsPendingRoundsWithoutPayingThem() public {
        _pendingNap();
        core.setReverting(true);
        _assertRecoverySwitch();
        assertEq(alice.balance, 0);
        assertEq(hook.napsSettled(), 0);
        // Restoring the old core later does not bring its dropped backlog back.
        core.setReverting(false);
        hook.settleNaps(1);
        assertEq(hook.napsSettled(), 0);
    }

    function test_codelessOldCoreCanBeReplaced() public {
        _pendingNap();
        vm.etch(address(core), "");
        _assertRecoverySwitch();
    }

    function test_malformedOldStateCanBeReplaced() public {
        _pendingNap();
        vm.mockCall(address(core), abi.encodeCall(ISqueekCore.state, ()), hex"ff");
        _assertRecoverySwitch();
    }

    function test_revertingOldPageCanBeReplacedWithReadableState() public {
        _pendingNap();
        core.setReadFailures(false, false, true);
        _assertRecoverySwitch();
    }

    function test_malformedOldPageCanBeReplaced() public {
        _pendingNap();
        vm.mockCall(address(core), abi.encodeCall(ISqueekCore.roundPage, (649, 653, 16)), hex"ff");
        _assertRecoverySwitch();
    }

    function test_nonProgressingOldPageCanBeReplaced() public {
        _pendingNap();
        ISqueekCore.RoundPage memory page;
        page.certifiedThroughRound = 649;
        vm.mockCall(address(core), abi.encodeCall(ISqueekCore.roundPage, (649, 653, 16)), abi.encode(page));
        _assertRecoverySwitch();
    }

    function test_oldConfigurationFailureDoesNotExcuseReadableCertifiedNap() public {
        _pendingNap();
        core.setReadFailures(false, true, false);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.NapsUnsettled.selector, uint64(650), uint64(653)));
        _switch();
        hook.settleNaps(1);
        _switch();
    }

    function test_readablePrefixMustBeSettledBeforeDroppingUnreadableLaterPage() public {
        _pendingNap();
        core.setFrontier(680);
        vm.mockCallRevert(
            address(core),
            abi.encodeCall(ISqueekCore.roundPage, (665, 680, 16)),
            abi.encodeWithSignature("BrokenPage()")
        );
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.NapsUnsettled.selector, uint64(650), uint64(680)));
        _switch();
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, 0.02 ether);
        assertEq(hook.scanRound(), 666);
        _switch();
        assertEq(hook.napsSettled(), 1);
        assertEq(hook.scanRound(), 8);
        assertBacked();
    }

    function test_regressingStateCannotHidePreviouslyObservedReadableNap() public {
        _pendingNap();
        vm.warp(roundEnd(653));
        buy(bob, 0.0001 ether); // observes the old core's frontier 653
        ISqueekCore.CoreState memory state;
        state.settledThroughRound = 649;
        vm.mockCall(address(core), abi.encodeCall(ISqueekCore.state, ()), abi.encode(state));
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.NapsUnsettled.selector, uint64(650), uint64(653)));
        _switch();
        vm.clearMockedCalls();
        hook.settleNaps(1);
        _switch();
        assertBacked();
    }

    function test_oldCoreBurningReadGasCannotPreventRecovery() public {
        _pendingNap();
        vm.etch(address(core), address(new GasBurnCore()).code);
        _readyReplacement();
        vm.prank(owner);
        hook.setCore{gas: 20_000_000}(replacement);
        assertEq(address(hook.core()), address(replacement));
        assertEq(hook.pot(), 0.02 ether);
        assertEq(hook.scanRound(), 8);
        assertBacked();
    }

    function test_ownerCannotStarveReadableOldStateToBypassPendingNap() public {
        _pendingNap();
        vm.etch(address(core), address(new GasSensitiveCore(false)).code);
        _assertCannotStarveOldRead(3_900_000);
    }

    function test_ownerCannotStarveReadableOldPageToBypassPendingNap() public {
        _pendingNap();
        vm.etch(address(core), address(new GasSensitiveCore(true)).code);
        _assertCannotStarveOldRead(6_000_000);
    }

    function _assertCannotStarveOldRead(uint256 gasBudget) internal {
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.NapsUnsettled.selector, uint64(650), uint64(653)));
        _switch();
        // Warm the new core as a transaction could do before the switch. An underfunded read
        // used to leave enough gas to switch, dropping a perfectly readable old-core nap.
        replacement.state();
        replacement.configuration();
        bytes32 beforeState = _snapshot();
        vm.expectRevert(HamsterNap3D.InsufficientCoreReadGas.selector);
        vm.prank(owner);
        hook.setCore{gas: gasBudget}(replacement);
        assertEq(_snapshot(), beforeState);
    }

    function test_oldCoreReturningOversizedDataCannotPreventRecovery() public {
        _pendingNap();
        vm.etch(address(core), address(new OversizedCore()).code);
        _readyReplacement();
        vm.prank(owner);
        hook.setCore{gas: 20_000_000}(replacement);
        assertEq(address(hook.core()), address(replacement));
        assertEq(hook.pot(), 0.02 ether);
        assertBacked();
    }

    function test_newCoreBurningReadGasIsRejectedAtomically() public {
        buy(alice, 1 ether);
        vm.etch(address(replacement), address(new GasBurnCore()).code);
        _assertSwitchFails(HamsterNap3D.CoreUnreadable.selector);
    }

    function test_newCoreReturningOversizedDataIsRejectedAtomically() public {
        buy(alice, 1 ether);
        vm.etch(address(replacement), address(new OversizedCore()).code);
        _assertSwitchFails(HamsterNap3D.CoreUnreadable.selector);
    }

    function test_newConfigurationRevertIsAtomic() public {
        buy(alice, 1 ether);
        replacement.setReadFailures(false, true, false);
        _assertSwitchFails(HamsterNap3D.CoreUnreadable.selector);
    }

    function test_newStateRevertIsAtomic() public {
        buy(alice, 1 ether);
        replacement.setReadFailures(true, false, false);
        _assertSwitchFails(HamsterNap3D.CoreUnreadable.selector);
    }

    function test_newZeroDurationIsAtomic() public {
        buy(alice, 1 ether);
        replacement.setConfiguration(GENESIS, 0);
        _assertSwitchFails(HamsterNap3D.InvalidRoundDuration.selector);
    }

    function test_newMalformedConfigurationIsAtomic() public {
        buy(alice, 1 ether);
        vm.mockCall(address(replacement), abi.encodeCall(ISqueekCore.configuration, ()), hex"01");
        _assertSwitchFails(HamsterNap3D.CoreUnreadable.selector);
    }

    function test_newMalformedStateIsAtomic() public {
        buy(alice, 1 ether);
        vm.mockCall(address(replacement), abi.encodeCall(ISqueekCore.state, ()), hex"01");
        _assertSwitchFails(HamsterNap3D.CoreUnreadable.selector);
    }

    function test_newOutOfRangeTimingIsAtomic() public {
        buy(alice, 1 ether);
        bytes memory raw = abi.encode(replacement.configuration());
        uint256 invalidGenesis = uint256(type(uint64).max) + 1;
        assembly ("memory-safe") {
            mstore(add(raw, 64), invalidGenesis)
        }
        vm.mockCall(address(replacement), abi.encodeCall(ISqueekCore.configuration, ()), raw);
        _assertSwitchFails(HamsterNap3D.CoreUnreadable.selector);
    }

    function test_newFrontierMustLeaveRoomForNextRound() public {
        buy(alice, 1 ether);
        ISqueekCore.CoreState memory state;
        state.settledThroughRound = type(uint64).max;
        vm.mockCall(address(replacement), abi.encodeCall(ISqueekCore.state, ()), abi.encode(state));
        _assertSwitchFails(HamsterNap3D.InvalidCoreFrontier.selector);
    }

    function test_newAddressWithoutCodeIsRejected() public {
        bytes32 beforeState = _snapshot();
        vm.expectRevert(HamsterNap3D.CoreUnreadable.selector);
        vm.prank(owner);
        hook.setCore(ISqueekCore(alice));
        vm.expectRevert(HamsterNap3D.CoreUnreadable.selector);
        vm.prank(owner);
        hook.setCore(ISqueekCore(address(0)));
        assertEq(_snapshot(), beforeState);
    }

    function test_invalidNewCoreCannotEraseOldUnreadableBacklog() public {
        _pendingNap();
        core.setReverting(true);
        replacement.setReverting(true);
        _assertSwitchFails(HamsterNap3D.CoreUnreadable.selector);
        core.setReverting(false);
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, 0.02 ether);
    }

    function test_buysBeforeSwitchWinNewNapAndBoundaryBuyWaits() public {
        buy(alice, 1 ether);
        HamsterNap3D.BuyRecord memory prior = hook.buyAt(0);
        _switch();
        assertEq(hook.pot(), 0.02 ether);
        assertEq(hook.latestBuyer(), alice);
        assertEq(keccak256(abi.encode(hook.buyAt(0))), keccak256(abi.encode(prior)));
        assertEq(hook.buyCount(), 1);
        vm.warp(hook.roundStart(8));
        buy(bob, 2 ether); // exactly the first second: excluded from this nap
        assertEq(hook.buyAt(0).round, 650);
        assertEq(hook.buyAt(1).round, 8); // historical round keys are no longer sorted
        (address winner, uint256 amount) = hook.winnerBefore(8);
        assertEq(winner, alice);
        assertEq(amount, 0.02 ether);
        vm.warp(hook.roundEnd(10));
        replacement.setFrontier(10);
        vm.expectEmit(true, true, false, true, address(hook));
        emit HamsterNap3D.NapSettled(8, alice, 0.02 ether);
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, 0.02 ether);
        assertEq(bob.balance, 0);
        assertEq(hook.pot(), 0.04 ether);
        assertEq(hook.latestBuyer(), bob);
        replacement.setWork(11, 1);
        replacement.setFrontier(14);
        vm.warp(hook.roundEnd(14));
        assertEq(hook.settleNaps(1), 1);
        assertEq(bob.balance, 0.04 ether);
        assertEq(hook.settleNaps(1), 0);
        assertEq(hook.pot(), 0);
        assertBacked();
    }

    function test_failsafeRestartsFromSwitchEvenWithLowerFrontier() public {
        buy(alice, 1 ether);
        uint256 oldOpening = hook.failsafeOpensAt();
        vm.warp(oldOpening + 1 days);
        replacement.setConfiguration(uint64(vm.getBlockTimestamp() - 10 * 120), 120);
        uint256 switchedAt = vm.getBlockTimestamp();
        _switch();
        assertEq(hook.lastSeenFrontier(), 7);
        assertEq(hook.frontierSeenAt(), switchedAt);
        assertEq(hook.failsafeOpensAt(), switchedAt + 7 days);
        replacement.setReverting(true);
        vm.warp(switchedAt + 7 days - 1);
        vm.expectRevert(abi.encodeWithSelector(HamsterNap3D.CoreNotStale.selector, switchedAt + 7 days));
        hook.failsafe();
        vm.warp(switchedAt + 7 days);
        vm.prank(owner); // even the owner triggering the failsafe pays only its rightful winner
        hook.failsafe();
        assertEq(alice.balance, 0.02 ether);
        assertEq(owner.balance, 0);
        assertBacked();
    }

    function test_switchAgainAndFinalizeDoNotResetClockOrRecordsUnexpectedly() public {
        buy(alice, 1 ether);
        _switch();
        buy(bob, 2 ether); // in the replacement's round 8
        vm.warp(vm.getBlockTimestamp() + 1);
        MockSqueekCore third = new MockSqueekCore();
        // The third core's round 21 starts exactly now: its frontier round 20 has just ended.
        third.setConfiguration(uint64(vm.getBlockTimestamp() - 20 * 31), 31);
        third.setFrontier(20);
        vm.prank(owner);
        hook.setCore(third);
        uint256 switchedAt = hook.frontierSeenAt();
        assertEq(switchedAt, hook.roundStart(21));
        buy(carol, 4 ether); // at the first second of round 21: excluded from a nap starting there
        vm.prank(owner);
        hook.finalizeCore();
        assertEq(hook.frontierSeenAt(), switchedAt);
        third.setFrontier(23);
        vm.warp(hook.roundEnd(23));
        assertEq(hook.settleNaps(1), 1);
        assertEq(bob.balance, 0.06 ether);
        assertEq(alice.balance, 0);
        assertEq(carol.balance, 0);
        assertEq(hook.pot(), 0.08 ether);
        assertEq(hook.buyCount(), 3);
        assertBacked();
    }

    function test_switchCarriesDeferredDebtAndFirstGameState() public {
        RejectingWinner winner = new RejectingWinner();
        buy(address(winner), 1 ether);
        core.setWork(650, 1);
        core.setFrontier(653);
        vm.warp(roundEnd(653));
        hook.settleNaps(1);
        buy(bob, 2 ether);
        assertEq(hook.owed(address(winner)), 0.02 ether);
        _switch();
        assertTrue(hook.firstNapSettled());
        assertEq(hook.napsSettled(), 1);
        assertEq(hook.cumulativePaid(), 0.02 ether);
        assertEq(hook.totalOwed(), 0.02 ether);
        assertEq(hook.owed(address(winner)), 0.02 ether);
        assertEq(hook.pot(), 0.04 ether);
        winner.setAccepting(true);
        winner.withdrawFrom(address(hook));
        assertEq(address(winner).balance, 0.02 ether);
        assertEq(hook.pot(), 0.04 ether);
        assertBacked();
    }

    function test_sellsAndFactoryFeeCollectionWorkAfterFinalizedCoreBreaks() public {
        buy(alice, 1 ether);
        _switch();
        vm.prank(owner);
        hook.finalizeCore();
        replacement.setReverting(true);
        uint256 clockBefore = hook.frontierSeenAt();
        assertGt(sell(bob, 1 ether).amount0(), 0);
        vm.prank(bob, bob);
        assertGt(swapper.swapExact(key, false, 0.001 ether).amount0(), 0);
        BalanceDelta collected =
            swapper.modifyLiquidity(key, TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), 0);
        assertGe(collected.amount0(), 0);
        assertGe(collected.amount1(), 0);
        assertEq(hook.frontierSeenAt(), clockBefore);
        assertEq(hook.latestBuyer(), alice);
        assertEq(hook.pot(), 0.02 ether);
        assertBacked();
    }

    function test_ownerCannotMigrateOrFinalizeFromPayoutCallback() public {
        CoreOwnerReceiver receiver = new CoreOwnerReceiver();
        vm.etch(owner, address(receiver).code);
        receiver = CoreOwnerReceiver(payable(owner));
        receiver.configure(hook, replacement);
        buy(owner, 1 ether);
        core.setWork(650, 1);
        core.setFrontier(653);
        vm.warp(roundEnd(653));
        assertEq(hook.settleNaps(1), 1);
        assertEq(receiver.switchError(), HamsterNap3D.Reentrancy.selector);
        assertEq(receiver.finalizeError(), HamsterNap3D.Reentrancy.selector);
        assertEq(address(hook.core()), address(core));
        assertFalse(hook.coreFinalized());
        assertEq(hook.scanRound(), 654);
        assertEq(owner.balance, 0.02 ether);
        assertBacked();
    }

    function test_ownerHasNoTransferPauseFeeUpgradeOrPotWithdrawalEntryPoints() public {
        buy(alice, 1 ether);
        string[7] memory signatures = [
            "transferOwnership(address)",
            "renounceOwnership()",
            "pause()",
            "upgradeTo(address)",
            "setFee(uint256)",
            "withdraw()",
            "withdrawPot(address)"
        ];
        for (uint256 i; i < signatures.length; i++) {
            vm.prank(owner);
            (bool ok,) = address(hook).call(abi.encodeWithSignature(signatures[i], owner));
            assertFalse(ok, signatures[i]);
        }
        assertEq(hook.owner(), owner);
        assertEq(owner.balance, 0);
        assertEq(hook.pot(), 0.02 ether);
        assertBacked();
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_crossCoreWinnerUsesTimeNotRound(
        uint64 durationSeed,
        uint64 frontierSeed,
        uint96 beforeSeed,
        uint96 duringSeed
    ) public {
        uint64 duration = uint64(bound(durationSeed, 1, 1 days));
        uint64 frontier = uint64(bound(frontierSeed, 0, 100));
        uint256 beforeGross = bound(beforeSeed, 0.001 ether, 10 ether);
        uint256 duringGross = bound(duringSeed, 0.001 ether, 10 ether);
        buy(alice, beforeGross);
        uint256 boundary = vm.getBlockTimestamp() + 100;
        // The new core's round `frontier + 1` starts at the boundary; the switch happens right then.
        replacement.setConfiguration(uint64(boundary - uint256(frontier) * duration), duration);
        replacement.setFrontier(frontier);
        vm.warp(boundary);
        _switch();
        buy(bob, duringGross);
        replacement.setFrontier(frontier + 3);
        vm.warp(boundary + uint256(duration) * 3);
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, fee(beforeGross));
        assertEq(bob.balance, 0);
        assertEq(hook.pot(), fee(duringGross));
        replacement.setWork(frontier + 4, 1);
        replacement.setFrontier(frontier + 7);
        vm.warp(boundary + uint256(duration) * 7);
        assertEq(hook.settleNaps(1), 1);
        assertEq(bob.balance, fee(duringGross));
        assertEq(hook.pot(), 0);
        assertBacked();
    }

    function _switch() internal {
        _readyReplacement();
        vm.prank(owner);
        hook.setCore(replacement);
    }

    /// @dev A switch is only valid once the replacement's frontier round has ended.
    function _readyReplacement() internal {
        if (vm.getBlockTimestamp() < replacementReady) vm.warp(replacementReady);
    }

    function _pendingNap() internal {
        buy(alice, 1 ether);
        core.setWork(650, 1);
        core.setFrontier(653);
    }

    function _assertRecoverySwitch() internal {
        uint256 feesBefore = hook.cumulativeFees();
        _switch();
        assertEq(address(hook.core()), address(replacement));
        assertEq(hook.scanRound(), 8);
        assertEq(hook.lastSeenFrontier(), 7);
        assertEq(hook.latestBuyer(), alice);
        assertEq(hook.buyCount(), 1);
        assertEq(hook.pot(), feesBefore);
        assertBacked();
    }

    function _assertSwitchFails(bytes4 reason) internal {
        bytes32 beforeState = _snapshot();
        vm.expectRevert(reason);
        _switch();
        assertEq(_snapshot(), beforeState, "failed switch changed game state");
        assertBacked();
    }

    function _snapshot() internal view returns (bytes32 result) {
        result = keccak256(
            abi.encode(
                hook.core(),
                hook.GENESIS_TIMESTAMP(),
                hook.ROUND_DURATION(),
                hook.scanRound(),
                hook.zeroRun(),
                hook.zeroRunStart(),
                hook.lastSeenFrontier(),
                hook.frontierSeenAt()
            )
        );
        result = keccak256(
            abi.encode(
                result,
                hook.latestBuyer(),
                hook.cumulativeFees(),
                hook.cumulativePaid(),
                hook.totalOwed(),
                hook.claimsHeld(),
                hook.napsSettled(),
                hook.firstNapSettled(),
                hook.buyCount(),
                address(hook).balance
            )
        );
        for (uint256 i; i < hook.buyCount(); i++) {
            result = keccak256(abi.encode(result, hook.buyAt(i)));
        }
    }
}

contract HamsterNap3DCoreClaimsTest is HookTestBase {
    function test_switchPreservesNativeClaimsAndRedeemsThemForNewNap() public {
        seedTokensOnly(1_000_000 ether);
        assertEq(address(manager).balance, 0);
        buy(alice, 1 ether);
        assertEq(hook.claimsHeld(), 0.02 ether);
        vm.warp(vm.getBlockTimestamp() + 1);
        MockSqueekCore replacement = new MockSqueekCore();
        replacement.setConfiguration(uint64(vm.getBlockTimestamp()), 31); // genesis now, frontier 0
        vm.prank(owner);
        hook.setCore(replacement);
        assertEq(hook.claimsHeld(), 0.02 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.02 ether);
        assertEq(hook.pot(), 0.02 ether);
        replacement.setFrontier(3);
        vm.warp(hook.roundEnd(3));
        assertEq(hook.settleNaps(1), 1);
        assertEq(alice.balance, 0.02 ether);
        assertEq(hook.claimsHeld(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertBacked();
    }
}

/// @dev Models code attached to the owner wallet; admin authorization succeeds, but the payout
/// lock must prevent a mid-scan timeline change. Not a production owner or deployment address.
contract CoreOwnerReceiver {
    HamsterNap3D private hook;
    ISqueekCore private replacement;
    bytes4 public switchError;
    bytes4 public finalizeError;

    function configure(HamsterNap3D hook_, ISqueekCore replacement_) external {
        hook = hook_;
        replacement = replacement_;
    }

    receive() external payable {
        (bool changed, bytes memory reason) = address(hook).call(abi.encodeCall(HamsterNap3D.setCore, (replacement)));
        require(!changed, "switched during payout");
        switchError = bytes4(reason);
        (bool finalized, bytes memory finalReason) = address(hook).call(abi.encodeCall(HamsterNap3D.finalizeCore, ()));
        require(!finalized, "finalized during payout");
        finalizeError = bytes4(finalReason);
    }
}

contract GasBurnCore {
    fallback() external {
        assembly ("memory-safe") {
            for {} 1 {} {}
        }
    }
}

contract OversizedCore {
    fallback() external {
        assembly ("memory-safe") {
            return(mload(0x40), 131072)
        }
    }
}

/// @dev A dependency that needs a full read budget. The cheaper state mode isolates starvation
/// of roundPage, while the other mode reproduces starvation of state itself.
contract GasSensitiveCore {
    bool private immutable expensivePage;

    constructor(bool expensivePage_) {
        expensivePage = expensivePage_;
    }

    function state() external view returns (ISqueekCore.CoreState memory result) {
        if (!expensivePage) {
            _needReadGas();
        } else {
            // Start with enough for state, then consume enough that the following page cannot
            // receive its full budget. This specifically exercises the second headroom check.
            uint256 stopAt = gasleft() - 2_000_000;
            while (gasleft() > stopAt) {}
        }
        result.settledThroughRound = 653;
    }

    function roundPage(uint64, uint64, uint256) external view returns (ISqueekCore.RoundPage memory page) {
        if (expensivePage) _needReadGas();
        page.certifiedThroughRound = 653;
    }

    function _needReadGas() private view {
        if (gasleft() < 4_000_000) {
            assembly ("memory-safe") {
                for {} 1 {} {}
            }
        }
    }
}
