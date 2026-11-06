// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {MockSqueekCore} from "./mocks/MockSqueekCore.sol";
import {CoreMigrationHandler} from "./independent/CoreMigrationHandler.sol";

/// @notice Repeated migrations must preserve every buy and all money, with unrelated core clocks.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract HamsterNap3DMigrationInvariantTest is HookTestBase {
    CoreMigrationHandler internal handler;

    function setUp() public override {
        super.setUp();
        vm.chainId(11155111);
        seedTokensOnly(1_000_000 ether);
        MockSqueekCore initial = new MockSqueekCore();
        initial.setConfiguration(uint64(vm.getBlockTimestamp()), 60);
        vm.prank(owner);
        hook.setCore(initial);
        handler = new CoreMigrationHandler(hook, swapper, key, initial, owner);
        handler.buy(1 ether, 0, 0); // First fee must be an ERC-6909 claim on the fresh manager.
        assertEq(hook.claimsHeld(), 0.02 ether);
        bytes4[] memory selectors = new bytes4[](_withFinalization() ? 12 : 11);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.sell.selector;
        selectors[2] = handler.certify.selector;
        selectors[3] = handler.coreStatus.selector;
        selectors[4] = handler.migrate.selector;
        selectors[5] = handler.unauthorized.selector;
        selectors[6] = handler.settle.selector;
        selectors[7] = handler.failsafeDuringOutage.selector;
        selectors[8] = handler.receiverStatus.selector;
        selectors[9] = handler.withdraw.selector;
        selectors[10] = handler.redeem.selector;
        if (_withFinalization()) selectors[11] = handler.finalize.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function _withFinalization() internal pure virtual returns (bool) {
        return false;
    }

    function invariant_migrationsPreserveHistoryWinnersDebtAndBacking() public view {
        handler.checkModel();
        assertEq(manager.balanceOf(address(hook), 0), hook.claimsHeld(), "actual ERC-6909 claim backing");
        assertEq(address(hook).balance + manager.balanceOf(address(hook), 0), hook.pot() + hook.totalOwed());
    }

    function test_handlerReachesBlockedMigrationDebtCarryoverAndFinalization() public {
        handler.buy(2 ether, 3, 0);
        handler.certify(240, 4, 1); // round 1 worked, then a nap starting at round 2
        handler.migrate(31, 7, 0);
        assertEq(handler.blockedMigrations(), 1);
        handler.settle(1);
        assertEq(hook.owed(address(handler.rejecting())), 0.06 ether);
        handler.migrate(31, 7, 0);
        assertEq(handler.migrations(), 1);
        assertEq(hook.owed(address(handler.rejecting())), 0.06 ether);
        handler.receiverStatus(true);
        handler.withdraw(3);
        assertEq(handler.withdrawals(), 1);
        handler.finalize();
        handler.migrate(60, 0, 0);
        assertEq(handler.finalizedRefusals(), 1);
        handler.buy(1 ether, 1, 0);
        handler.failsafeDuringOutage(0);
        assertEq(handler.failsafes(), 0);
        handler.failsafeDuringOutage(1);
        assertEq(handler.failsafes(), 1);
        handler.checkModel();
    }

    function test_handlerReachesUnreadableMigrationInvalidCandidatesAndRepeatedPayouts() public {
        handler.certify(240, 4, 1);
        handler.coreStatus(2); // readable state, unreadable pending page
        handler.migrate(1, 0, 1);
        assertEq(handler.invalidCandidates(), 1);
        handler.migrate(31, 7, 0);
        assertEq(handler.migrations(), 1);
        handler.unauthorized(false, 1);
        handler.unauthorized(true, 2);
        assertEq(handler.unauthorizedRefusals(), 2);
        handler.failsafeDuringOutage(1);
        assertEq(handler.failsafes(), 1);
        handler.buy(2 ether, 2, 0);
        handler.migrate(1, 24, 0);
        assertEq(handler.migrations(), 2);
        handler.failsafeDuringOutage(1);
        assertEq(handler.failsafes(), 2);
        handler.checkModel();
    }
}

/// @notice A second campaign adds finalization at arbitrary points without ending the other actions.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract HamsterNap3DMigrationFinalizedInvariantTest is HamsterNap3DMigrationInvariantTest {
    function _withFinalization() internal pure override returns (bool) {
        return true;
    }
}
