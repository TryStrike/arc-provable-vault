// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ProvableVault} from "../src/ProvableVault.sol";

/// Deploys a ProvableVault. No keys live in this file: pass the signer on the command line
/// (`--account`, `--ledger` or `--private-key`).
///
/// Env:
///   OWNER           required. The admin. Use a multisig or cold key, not the deploy wallet.
///   OPERATOR        required. The hot key that pays out and commits results.
///   TOKEN_MESSENGER optional. CCTP V2 TokenMessenger. Defaults to the Arc testnet one.
///
/// The owner then sets caps with `setCap`. Until it does, nothing can be paid out.
contract Deploy is Script {
    address internal constant ARC_TESTNET_TOKEN_MESSENGER = 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA;

    function run() external returns (ProvableVault vault) {
        address owner = vm.envAddress("OWNER");
        address operator = vm.envAddress("OPERATOR");
        address tokenMessenger = vm.envOr("TOKEN_MESSENGER", ARC_TESTNET_TOKEN_MESSENGER);

        vm.startBroadcast();
        vault = new ProvableVault(tokenMessenger, owner, operator);
        vm.stopBroadcast();

        console.log("ProvableVault:", address(vault));
        console.log("owner:", owner);
        console.log("operator:", operator);
        console.log("tokenMessenger:", tokenMessenger);
    }
}
