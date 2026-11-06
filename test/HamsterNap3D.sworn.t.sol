// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {HamsterNap3D} from "../src/HamsterNap3D.sol";
import {MockSworn} from "./mocks/MockSworn.sol";

/// @notice The first game is for Sworn card holders on Ethereum mainnet only.
contract HamsterNap3DSwornTest is HookTestBase {
    MockSworn sworn;

    function setUp() public override {
        super.setUp();
        seedBothSides(1_000_000 ether);
        workThrough(1, 649);
        sworn = MockSworn(address(hook.SWORN()));
        vm.etch(address(sworn), address(new MockSworn()).code);
    }

    function test_onSepoliaAnyoneBuysFromTheStart() public {
        vm.chainId(11155111);
        assertTrue(hook.mayBuy(alice));
        buy(alice, 1 ether);
        assertEq(hook.latestBuyer(), alice);
    }

    function test_onMainnetFirstGameNeedsACard() public {
        vm.chainId(1);
        assertFalse(hook.mayBuy(alice));
        vm.expectRevert();
        buy(alice, 1 ether);
        assertEq(hook.buyCount(), 0);

        sworn.setBalance(alice, 1);
        assertTrue(hook.mayBuy(alice));
        buy(alice, 1 ether);
        assertEq(hook.latestBuyer(), alice);
    }

    function test_onMainnetTheCheckIsReadLive() public {
        vm.chainId(1);
        sworn.setBalance(bob, 1);
        buy(bob, 1 ether);
        // A wallet that mints a card after the first swap joins at once.
        vm.expectRevert();
        buy(carol, 1 ether);
        sworn.setBalance(carol, 2);
        buy(carol, 1 ether);
        assertEq(hook.latestBuyer(), carol);
        // A card that is transferred away shuts the wallet out again.
        sworn.setBalance(bob, 0);
        vm.expectRevert();
        buy(bob, 1 ether);
    }

    function test_onMainnetSellsAlwaysWork() public {
        vm.chainId(1);
        sell(alice, 100 ether);
        assertEq(hook.scanRound(), 650, "a sell starts the game too");
        // Even with the registry dead.
        vm.etch(address(sworn), "");
        sell(alice, 100 ether);
        vm.expectRevert();
        buy(alice, 1 ether);
    }

    function test_onMainnetAnyoneBuysAfterTheFirstNap() public {
        vm.chainId(1);
        sworn.setBalance(alice, 1);
        warpToRound(651);
        buy(alice, 1 ether);
        workThrough(650, 659);
        sleepThrough(660, 662);
        warpToRound(663);
        assertTrue(hook.firstGame());
        hook.settleNaps(10);
        assertFalse(hook.firstGame());
        assertTrue(hook.mayBuy(bob));
        buy(bob, 1 ether);
        assertEq(hook.latestBuyer(), bob);
    }

    function test_otherChainsSkipTheCheck() public {
        vm.chainId(8453);
        buy(alice, 1 ether);
        assertEq(hook.latestBuyer(), alice);
    }
}
