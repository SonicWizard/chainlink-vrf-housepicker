// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {HousePicker} from "../src/HousePicker.sol";

contract DeployHousePicker is Script {
    function run() external returns (HousePicker housePicker) {
        // Set VRF_SUBSCRIPTION_ID in .env (see .env.example) to a funded
        // Sepolia VRF v2.5 subscription you own.
        uint256 subscriptionId = vm.envUint("VRF_SUBSCRIPTION_ID");

        vm.startBroadcast();
        housePicker = new HousePicker(subscriptionId);
        vm.stopBroadcast();

        console.log("HousePicker deployed to:", address(housePicker));
        console.log("Subscription ID:", subscriptionId);
        console.log("Next: add the contract as a consumer at https://vrf.chain.link/sepolia");
    }
}
