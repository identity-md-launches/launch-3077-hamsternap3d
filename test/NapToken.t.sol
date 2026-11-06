// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NapToken} from "../src/NapToken.sol";

contract NapTokenTest is Test {
    NapToken token;

    function setUp() public {
        token = new NapToken();
    }

    function test_supplyMintedToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "Hamster Nap 3D");
        assertEq(token.symbol(), "NAP");
    }

    function test_transferMovesExactly() public {
        address to = makeAddr("to");
        assertTrue(token.transfer(to, 1234 ether));
        assertEq(token.balanceOf(to), 1234 ether);
        assertEq(token.balanceOf(address(this)), 1e27 - 1234 ether);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferBeyondBalanceReverts() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        token.transfer(address(this), 1);
    }

    function test_noMintFunction() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), 1e27);
    }
}
