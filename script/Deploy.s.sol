// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {Marketplace} from "../src/Marketplace.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(pk);
        address feeRecipient = vm.envOr("FEE_RECIPIENT", owner);
        address usdc = vm.envAddress("USDC");
        address usdt = vm.envOr("USDT", address(0));

        vm.startBroadcast(pk);
        Marketplace m = new Marketplace(owner, feeRecipient, 100, 0);
        m.setAllowedToken(usdc, true);
        if (usdt != address(0)) m.setAllowedToken(usdt, true);
        vm.stopBroadcast();
    }
}
