// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {SequenceCore} from "./independent/SequenceCore.sol";
import {NapSequenceHandler} from "./independent/NapSequenceHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract HamsterNap3DInvariantTest is HookTestBase {
    NapSequenceHandler private handler;

    function setUp() public override {
        super.setUp();
        vm.chainId(11155111);
        SequenceCore sequenceCore = SequenceCore(address(core));
        vm.etch(address(sequenceCore), address(new SequenceCore()).code);
        sequenceCore.initialize(649);
        // First buy mints claims, later trades usually take ETH. Both representations are exercised.
        seedTokensOnly(1_000_000 ether);
        handler = new NapSequenceHandler(hook, sequenceCore, swapper, key);
        handler.buy(1 ether, 0, 2);
        bytes4[] memory selectors = new bytes4[](_includeFailsafe() ? 11 : 9);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.sell.selector;
        selectors[2] = handler.advanceAndCertify.selector;
        selectors[3] = handler.coreStatus.selector;
        selectors[4] = handler.settle.selector;
        selectors[5] = handler.redeem.selector;
        selectors[6] = handler.receiverStatus.selector;
        selectors[7] = handler.withdraw.selector;
        selectors[8] = handler.buyLimited.selector;
        if (_includeFailsafe()) {
            selectors[9] = handler.takeFailsafeAfterSevenUnchangedDays.selector;
            selectors[10] = handler.takeFailsafeAfterExtraWait.selector;
        }
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function _includeFailsafe() internal pure virtual returns (bool) {
        return false;
    }

    function invariant_valueAndWinnerModelMatchesAfterEverySequence() public view {
        handler.checkModel();
        assertEq(manager.balanceOf(address(hook), 0), hook.claimsHeld(), "actual ERC6909 backing");
        assertEq(address(hook).balance + manager.balanceOf(address(hook), 0), hook.pot() + hook.totalOwed());
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(address(swapper)) + token.balanceOf(address(manager)),
            token.totalSupply(),
            "trading cannot create or destroy NAP"
        );
    }

    function test_handlerReachesClaimDebtWithdrawalAndFailsafe() public {
        // Deterministic reachability companion: random campaigns are not the only evidence
        // that the handler can execute claims and a successful deferred withdrawal.
        handler.buy(1 ether, 3, 2);
        handler.advanceAndCertify(2400, 4, 1); // work at 650, sleep 651..653
        handler.settle(1);
        assertEq(handler.naps(), 1);
        assertGt(hook.totalOwed(), 0);
        handler.receiverStatus(true);
        handler.withdraw(3);
        assertEq(handler.withdrawals(), 1);
        handler.buy(2 ether, 1, 2);
        handler.coreStatus(1);
        handler.takeFailsafeAfterSevenUnchangedDays();
        assertEq(handler.failsafes(), 1);
        handler.checkModel();
    }

    function test_handlerReachesPartialRefundAndUnseenAdvanceKeepsFailsafeShut() public {
        handler.buyLimited(10 ether, 1, 1, false); // 10 ETH offered, limit 1e-8 below the price
        assertEq(handler.partialFills(), 1);
        assertGt(hook.owed(handler.actors(1)), 0);
        handler.withdraw(1);
        handler.checkModel();
        // Eight days pass, then the core certifies rounds that ended long ago, unseen by the hook.
        vm.warp(block.timestamp + 8 days);
        handler.advanceAndCertify(0, 16, 0);
        uint256 failsBefore = handler.failsafes();
        handler.takeFailsafeAfterSevenUnchangedDays(); // expects CoreNotStale(now + 7 days)
        assertEq(handler.failsafes(), failsBefore);
        handler.settle(1); // a claim call records the sighting
        assertEq(hook.frontierSeenAt(), block.timestamp);
        handler.takeFailsafeAfterSevenUnchangedDays();
        handler.checkModel();
    }

    function test_handlerReachesFailsafeScanAndUnsettledBacklogRefusal() public {
        // Rounds 650..658 certified with work only at 650: the nap 651..653 is certified but unscanned.
        handler.buy(1 ether, 0, 2); // Alice, before the nap
        vm.warp(block.timestamp + 7200);
        handler.advanceAndCertify(0, 9, 1);
        handler.buy(2 ether, 1, 2); // Bob, after the nap: observes the frontier, does not settle it
        assertEq(hook.napsSettled(), 0);
        handler.takeFailsafeAfterSevenUnchangedDays();
        assertEq(handler.failsafes(), 1);
        assertEq(handler.failsafeNaps(), 1, "the failsafe settled the certified nap first");
        assertEq(hook.napsSettled(), 1);
        assertEq(hook.scanRound(), 659);
        assertGt(handler.actors(0).balance, 0, "Alice's nap was paid to Alice");
        handler.checkModel();

        // A backlog of more than eight pages refuses the failsafe until settleNaps catches up.
        handler.buy(1 ether, 2, 2);
        vm.warp(block.timestamp + 2 days);
        for (uint256 i; i < 10; i++) {
            handler.advanceAndCertify(0, 16, type(uint16).max); // 160 worked rounds
        }
        handler.buy(1 ether, 2, 2); // observe the frontier
        handler.takeFailsafeAfterSevenUnchangedDays();
        assertEq(handler.unsettledRefusals(), 1);
        handler.settle(3);
        handler.settle(3);
        handler.settle(3);
        handler.takeFailsafeAfterSevenUnchangedDays();
        assertEq(handler.failsafes(), 2);
        handler.checkModel();
    }

    function test_handlerReachesRollingFailsafeCutoffWithDeadCore() public {
        handler.coreStatus(1); // the core reverts from here on
        handler.takeFailsafeAfterSevenUnchangedDays(); // the setUp buyer takes the fees through the opening
        assertEq(handler.failsafes(), 1);
        handler.buy(1 ether, 1, 2); // Bob, after the payout
        handler.takeFailsafeAfterExtraWait(0); // Bob's buy is not seven days old: NothingToPay
        assertEq(handler.failsafes(), 1);
        handler.takeFailsafeAfterExtraWait(uint32(7 days + 1));
        assertEq(handler.failsafes(), 2);
        assertEq(handler.actors(1).balance, 0.02 ether, "the later qualifying buyer is paid its own fee");
        assertEq(hook.pot(), 0);
        handler.checkModel();
    }
}

/// @notice A separate campaign lets the ordinary one explore many timely naps, while this
/// campaign mixes prolonged outages and failsafes into the same accounting model.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract HamsterNap3DRecoveryInvariantTest is HamsterNap3DInvariantTest {
    function _includeFailsafe() internal pure override returns (bool) {
        return true;
    }
}
