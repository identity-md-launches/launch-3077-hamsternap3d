// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {NapToken} from "src/NapToken.sol";
import {HamsterNap3D} from "src/HamsterNap3D.sol";
import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";
import {HookTestBase} from "./HookTestBase.sol";
import {Swapper} from "./mocks/Swapper.sol";
import {MockSqueekCore} from "./mocks/MockSqueekCore.sol";
import {SepoliaRounds} from "./fixtures/SepoliaRounds.sol";
import {HookFlags} from "src/HookFlags.sol";

/// @notice Retains the earlier deployment's archival replay against its unmodified old proxy.
/// Opt in with forge's --fork-url and --fork-block-number 12030457. This is not evidence for the
/// new proxy, which did not exist at this block. The harness changes only the hook's initial literals.
contract HamsterNap3DForkTest is HookTestBase {
    uint256 private constant FORK_BLOCK = 12030457;
    uint64 private constant HISTORICAL_GENESIS = 1793022600;
    ISqueekCore private liveCore;
    uint256 private forkTimestamp;

    function setUp() public override {
        try vm.activeFork() returns (uint256) {}
        catch {
            vm.skip(true);
            return;
        }
        assertEq(block.number, FORK_BLOCK);
        assertEq(block.chainid, 11155111);
        forkTimestamp = block.timestamp;
        manager = new PoolManager(address(this));
        // Deterministic local deployment addresses can already have ETH on the fork.
        vm.deal(address(manager), 0);
        token = new NapToken();
        hook = _deployHistoricalHook();
        liveCore = hook.core();
        assertGt(address(liveCore).code.length, 0, "live proxy must exist");
        key = PoolKey(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token)), POOL_FEE, TICK_SPACING, IHooks(address(hook))
        );
        vm.prank(factory);
        manager.initialize(key, SQRT_PRICE_1_1);
        swapper = new Swapper(manager);
        vm.deal(address(swapper), 2_000_000 ether);
        token.transfer(address(swapper), 900_000_000 ether);
        seedTokensOnly(1_000_000 ether);
    }

    function testFork_configurationAndCertifiedFrontier() public view {
        ISqueekCore.CoreConfiguration memory config = liveCore.configuration();
        ISqueekCore.CoreState memory state = liveCore.state();
        assertEq(config.genesisTimestamp, HISTORICAL_GENESIS);
        assertEq(config.roundDuration, ROUND);
        assertEq(config.maxRoundsPerBatch, 16);
        assertGe(state.settledThroughRound, 642);
        assertLt(state.settledThroughRound, hook.currentRound(), "only closed rounds are certified");
        assertLe(hook.roundEnd(state.settledThroughRound), forkTimestamp);
    }

    function testFork_everyCapturedRoundMatchesLivePages() public {
        // The capture models work and cumulative work only; synthetic hashes/block units are not compared.
        MockSqueekCore captured = new MockSqueekCore();
        SepoliaRounds.load(captured);
        for (uint64 from = 482; from < 642; from += 16) {
            ISqueekCore.RoundPage memory expected = captured.roundPage(from, from + 16, 16);
            ISqueekCore.RoundPage memory actual = liveCore.roundPage(from, from + 16, 16);
            assertEq(actual.certifiedThroughRound, expected.certifiedThroughRound);
            assertEq(actual.start.cumulativeWork, expected.start.cumulativeWork);
            assertEq(actual.end.cumulativeWork, expected.end.cumulativeWork);
            assertEq(actual.rounds.length, expected.rounds.length);
            for (uint256 i; i < expected.rounds.length; i++) {
                assertEq(actual.rounds[i].roundId, expected.rounds[i].roundId);
                assertEq(actual.rounds[i].cumulativeWork, expected.rounds[i].cumulativeWork);
            }
        }
    }

    function testFork_pageBoundsAndSparseNapAreReal() public {
        ISqueekCore.RoundPage memory page = liveCore.roundPage(502, 505, 16);
        assertEq(page.certifiedThroughRound, 505);
        assertEq(page.rounds.length, 0);
        assertEq(page.start.cumulativeWork, page.end.cumulativeWork);
        page = liveCore.roundPage(530, 546, 16);
        assertEq(page.rounds.length, 1);
        assertEq(page.rounds[0].roundId, 539);
        uint64 frontier = liveCore.state().settledThroughRound;
        vm.expectRevert(ISqueekCore.InvalidRoundPageBounds.selector);
        liveCore.roundPage(610, 600, 16);
        vm.expectRevert(ISqueekCore.InvalidRoundPageBounds.selector);
        liveCore.roundPage(frontier, frontier + 1, 16);
        vm.expectRevert(ISqueekCore.InvalidRoundPageBounds.selector);
        liveCore.roundPage(600, 620, 17);
    }

    function testFork_livePagesSettleBoundaryBuysInOrder() public {
        // Local buy timestamps replay the historical window; the fork block and live core are never changed.
        vm.warp(roundStart(503) - 1);
        buy(alice, 1 ether);
        warpToRound(503);
        buy(bob, 2 ether);
        warpToRound(539);
        buy(carol, 4 ether);
        vm.warp(forkTimestamp);

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;
        uint256 carolBefore = carol.balance;
        vm.expectEmit(true, true, false, true, address(hook));
        emit HamsterNap3D.NapSettled(503, alice, 0.02 ether);
        assertEq(hook.settleNaps(1), 1); // rounds 502..517
        assertEq(alice.balance - aliceBefore, 0.02 ether);
        assertEq(bob.balance, bobBefore);
        assertEq(hook.pot(), 0.12 ether);
        vm.expectEmit(true, true, false, true, address(hook));
        emit HamsterNap3D.NapSettled(519, bob, 0.04 ether);
        assertEq(hook.settleNaps(1), 1); // rounds 518..533
        vm.expectEmit(true, true, false, true, address(hook));
        emit HamsterNap3D.NapSettled(540, carol, 0.08 ether);
        assertEq(hook.settleNaps(1), 1); // rounds 534..549
        assertEq(bob.balance - bobBefore, 0.04 ether);
        assertEq(carol.balance - carolBefore, 0.08 ether);
        assertEq(hook.pot(), 0);
        assertEq(hook.claimsHeld(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertBacked();
    }

    function testFork_currentBuysObserveCoreAndSellsPreservePot() public {
        uint64 frontier = liveCore.state().settledThroughRound;
        BalanceDelta bought = buy(alice, 0.001 ether);
        assertGt(bought.amount1(), 0);
        assertEq(hook.latestBuyer(), alice);
        assertEq(hook.lastSeenFrontier(), frontier);
        assertEq(hook.claimsHeld(), 0.00002 ether);
        hook.redeemClaims();
        BalanceDelta sold = sell(bob, uint256(uint128(bought.amount1())) / 2);
        assertGt(sold.amount0(), 0);
        assertEq(hook.settleNaps(1), 0, "current round is not certified");
        assertEq(hook.pot(), 0.00002 ether);
        assertEq(hook.latestBuyer(), alice);
        assertBacked();
    }

    function roundStart(uint64 round) internal pure override returns (uint256) {
        return HISTORICAL_GENESIS + uint256(round - 1) * ROUND;
    }

    function roundEnd(uint64 round) internal pure override returns (uint256) {
        return HISTORICAL_GENESIS + uint256(round) * ROUND;
    }

    function _deployHistoricalHook() private returns (HamsterNap3D deployed) {
        bytes32 initHash =
            keccak256(abi.encodePacked(type(HistoricalReplayHook).creationCode, abi.encode(manager, factory, owner)));
        for (uint256 i; i < 500_000; i++) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initHash))))
            );
            if (!HookFlags.matches(predicted, HOOK_FLAGS)) continue;
            return new HistoricalReplayHook{salt: bytes32(i)}(manager, factory, owner);
        }
        revert("no historical replay salt");
    }
}

/// @dev Test-only fixture for the original captured ledger. No changes to the external proxy.
contract HistoricalReplayHook is HamsterNap3D {
    constructor(IPoolManager manager_, address factory_, address owner_) HamsterNap3D(manager_, factory_, owner_) {
        core = ISqueekCore(0x980B4424c007CAf7a1f3670B48c8EaEf7EbC3d44);
        GENESIS_TIMESTAMP = 1793022600;
    }
}
