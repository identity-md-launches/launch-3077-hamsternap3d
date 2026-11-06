// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {HookTestBase} from "./HookTestBase.sol";
import {HamsterNap3D} from "../src/HamsterNap3D.sol";

/// @notice A fresh PoolManager whose pool was seeded with tokens only holds no ETH when the first
/// buy's fee is due, so the hook takes an ERC-6909 claim instead and redeems it before paying.
contract HamsterNap3DClaimsTest is HookTestBase {
    function setUp() public override {
        super.setUp();
        seedTokensOnly(1_000_000 ether);
        workThrough(1, 649);
        assertEq(address(manager).balance, 0, "the manager starts with no ETH");
    }

    function test_firstBuyOnTokenOnlyPoolMintsAClaim() public {
        vm.expectEmit(true, false, false, true);
        emit HamsterNap3D.Buy(alice, 1 ether, 0.02 ether, 650, true);
        BalanceDelta delta = buy(alice, 1 ether);
        assertEq(delta.amount0(), -1 ether);
        assertGt(delta.amount1(), 0);
        assertEq(hook.pot(), 0.02 ether);
        assertEq(address(hook).balance, 0, "no ETH could be taken yet");
        assertEq(hook.claimsHeld(), 0.02 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.02 ether, "an ETH claim on the manager");
        assertEq(address(manager).balance, 1 ether, "the buyer's ETH, fee included, sits in the manager");
        assertBacked();
    }

    function test_exactOutputBuyOnTokenOnlyPoolMintsAClaim() public {
        BalanceDelta delta = buyExactOut(alice, 1000 ether);
        uint256 gross = uint256(uint128(-delta.amount0()));
        assertApproxEqAbs(hook.claimsHeld(), gross * 200 / 10_000, 1);
        assertEq(hook.claimsHeld(), hook.pot());
        assertBacked();
    }

    function test_laterBuysTakeEthOnceTheManagerHoldsIt() public {
        buy(alice, 1 ether);
        buy(bob, 1 ether);
        assertEq(hook.claimsHeld(), 0.02 ether, "only the first fee is a claim");
        assertEq(address(hook).balance, 0.02 ether, "the second fee came as ETH");
        assertBacked();
    }

    function test_anyoneRedeemsClaims() public {
        buy(alice, 1 ether);
        vm.prank(carol);
        vm.expectEmit(false, false, false, true);
        emit HamsterNap3D.ClaimsRedeemed(0.02 ether);
        hook.redeemClaims();
        assertEq(hook.claimsHeld(), 0);
        assertEq(address(hook).balance, 0.02 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertBacked();
        hook.redeemClaims(); // nothing left: a no-op
    }

    function test_napPayoutRedeemsClaimsFirst() public {
        warpToRound(651);
        buy(alice, 1 ether);
        workThrough(650, 659);
        sleepThrough(660, 662);
        warpToRound(663);
        assertEq(hook.settleNaps(10), 1);
        assertEq(alice.balance, 0.02 ether);
        assertEq(hook.claimsHeld(), 0);
        assertEq(hook.pot(), 0);
        assertBacked();
    }

    function test_failsafeRedeemsClaimsFirst() public {
        buy(alice, 1 ether);
        vm.warp(hook.failsafeOpensAt());
        hook.failsafe();
        assertEq(alice.balance, 0.02 ether);
        assertEq(hook.claimsHeld(), 0);
        assertBacked();
    }

    function test_sellOnTokenOnlyPoolAfterABuy() public {
        buy(alice, 1 ether);
        BalanceDelta sold = sell(bob, 100 ether);
        assertGt(sold.amount0(), 0);
        assertEq(hook.pot(), 0.02 ether);
    }
}
