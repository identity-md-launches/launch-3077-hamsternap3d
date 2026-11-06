// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Hamster Nap 3D (NAP)
/// @notice The launch token: a plain fixed-supply ERC-20. One billion tokens at 18 decimals are
/// minted once to the deployer (the launch factory). No owner, no mint, no pause, no fee, no
/// blocklist, no upgrade. The game's 2% buy fee lives in the hook, not here.
contract NapToken is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("Hamster Nap 3D", "NAP") {
        _mint(msg.sender, SUPPLY);
    }
}
