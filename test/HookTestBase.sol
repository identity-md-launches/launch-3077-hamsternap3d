// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {HamsterNap3D} from "../src/HamsterNap3D.sol";
import {NapToken} from "../src/NapToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {Swapper} from "./mocks/Swapper.sol";
import {MockSqueekCore} from "./mocks/MockSqueekCore.sol";

/// @notice Shared scaffolding: a PoolManager, the NAP token, the hook mined onto its flags, a mock
/// SqueekCore etched at the hook's initial core address, and a funded test router.
abstract contract HookTestBase is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant POOL_FEE = 12_500;
    int24 internal constant TICK_SPACING = 60;
    uint64 internal constant GENESIS = 1793735400;
    uint64 internal constant ROUND = 600;
    uint160 internal constant HOOK_FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    address internal owner = makeAddr("owner");
    address internal factory = makeAddr("factory");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    PoolManager internal manager;
    NapToken internal token;
    HamsterNap3D internal hook;
    MockSqueekCore internal core;
    Swapper internal swapper;
    PoolKey internal key;
    /// @dev Where the next salt search starts, so a second hook in one test never reuses a salt.
    uint256 internal nextSalt;

    function setUp() public virtual {
        // A moment in round 650. Historical work fixtures are replayed on the new default timing.
        vm.warp(roundStart(650) + 17);
        manager = new PoolManager(address(this));
        token = new NapToken();
        hook = deployHook(manager, factory);
        core = MockSqueekCore(address(hook.core()));
        vm.etch(address(core), address(new MockSqueekCore()).code);
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        vm.prank(factory);
        manager.initialize(key, SQRT_PRICE_1_1);

        swapper = new Swapper(manager);
        vm.deal(address(swapper), 1_000_000_000 ether);
        token.transfer(address(swapper), 900_000_000 ether);
    }

    // ---------------------------------------------------------------- deployment

    /// @dev Mines a CREATE2 salt from this contract so the hook lands on an address carrying its flags.
    function deployHook(IPoolManager manager_, address factory_) internal returns (HamsterNap3D deployed) {
        bytes memory creationCode =
            abi.encodePacked(type(HamsterNap3D).creationCode, abi.encode(manager_, factory_, owner));
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = nextSalt; i < nextSalt + 500_000; i++) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initCodeHash))))
            );
            if (!HookFlags.matches(predicted, HOOK_FLAGS)) continue;
            deployed = new HamsterNap3D{salt: bytes32(i)}(manager_, factory_, owner);
            require(address(deployed) == predicted, "mined address mismatch");
            nextSalt = i + 1;
            return deployed;
        }
        revert("no salt found");
    }

    // ---------------------------------------------------------------- liquidity

    /// @dev Full-range liquidity: the manager holds both ETH and NAP afterwards.
    function seedBothSides(uint256 liquidity) internal {
        swapper.modifyLiquidity(
            key, TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), int256(liquidity)
        );
    }

    /// @dev A position entirely below the current price: the manager holds NAP only, no ETH.
    function seedTokensOnly(uint256 liquidity) internal {
        swapper.modifyLiquidity(key, TickMath.minUsableTick(TICK_SPACING), -TICK_SPACING, int256(liquidity));
    }

    // ---------------------------------------------------------------- trading

    function buy(address buyer, uint256 ethIn) internal returns (BalanceDelta) {
        vm.prank(buyer, buyer);
        return swapper.swap(key, true, ethIn);
    }

    function buyExactOut(address buyer, uint256 tokensOut) internal returns (BalanceDelta) {
        vm.prank(buyer, buyer);
        return swapper.swapExact(key, true, int256(tokensOut));
    }

    function sell(address seller, uint256 tokensIn) internal returns (BalanceDelta) {
        vm.prank(seller, seller);
        return swapper.swap(key, false, tokensIn);
    }

    /// @dev A buy the pool may fill only partly: it stops at `limit` (a sqrt price below the current one).
    /// Negative `amountSpecified` is exact input (ETH), positive exact output (NAP).
    function buyWithLimit(address buyer, int256 amountSpecified, uint160 limit) internal returns (BalanceDelta) {
        vm.prank(buyer, buyer);
        return swapper.swapWithLimit(key, true, amountSpecified, limit);
    }

    /// @dev The pool's current sqrt price.
    function currentSqrtPrice() internal view returns (uint160 sqrtPrice) {
        (sqrtPrice,,,) = StateLibrary.getSlot0(manager, key.toId());
    }

    // ---------------------------------------------------------------- rounds and the core

    function roundStart(uint64 round) internal pure virtual returns (uint256) {
        return GENESIS + uint256(round - 1) * ROUND;
    }

    function roundEnd(uint64 round) internal pure virtual returns (uint256) {
        return GENESIS + uint256(round) * ROUND;
    }

    function warpToRound(uint64 round) internal {
        vm.warp(roundStart(round));
    }

    /// @dev Marks every round from `from` through `through` as worked, and certifies through `through`.
    function workThrough(uint64 from, uint64 through) internal {
        core.setWorkRange(from, through, 500);
        if (through > core.frontier()) core.setFrontier(through);
    }

    /// @dev Leaves `from..through` at zero work and certifies through `through`.
    function sleepThrough(uint64 from, uint64 through) internal {
        core.setWorkRange(from, through, 0);
        if (through > core.frontier()) core.setFrontier(through);
    }

    function fee(uint256 gross) internal pure returns (uint256) {
        return gross * 200 / 10_000;
    }

    /// @dev The hook's ETH and claims always cover the pot plus what deferred winners are owed.
    function assertBacked() internal view {
        assertEq(address(hook).balance + hook.claimsHeld(), hook.pot() + hook.totalOwed(), "pot not backed");
        assertEq(hook.pot(), hook.cumulativeFees() - hook.cumulativePaid(), "pot identity");
    }
}
