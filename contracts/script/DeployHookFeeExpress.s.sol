// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {HookVanity} from "../src/HookVanity.sol";
import {StonkzExpressFactory} from "../src/StonkzExpressFactory.sol";

/// @title DeployHookFeeExpress — BROADCAST: FeeHook + CTOGovernor only (ladder settlement deferred)
/// @notice Deployer txs: CTOGovernor, StonkzFeeHook{salt}, setRegistry, transferOwnership(custody).
///         Safe (post): Express.setHook(newHook), Express.setGovernor(newGov).
///         NO LadderSettlement / setSettlementRef / adapter.setAuthorized this phase.
///
/// ENV: PRIVATE_KEY, HOOK_CREATE2_SALT (mined for current deployer nonce)
///   forge script script/DeployHookFeeExpress.s.sol:DeployHookFeeExpress \
///     --rpc-url $ROBINHOOD_RPC_URL --broadcast -vvvv
contract DeployHookFeeExpress is Script {
    uint256 internal constant CHAIN_ROBINHOOD = 4663;
    uint256 internal constant EIP170_MAX = 24_576;

    address internal constant EXPRESS = 0xEe2590c39E1485ed2F9cdaA684ab7B91d284E94a;
    address internal constant LIVE_HOOK = 0x4663c4c5Cb6F826d148cD38aDaF9157f483d0088;
    address internal constant SAFE_DEFAULT = 0x9D116B03FA6eB7F02c232670Bc083530609c5572;
    address internal constant AUGUST_DEPLOYER = 0x8F5077eC52543d6393F483dC2B958Bf8Cad2d232;

    error WrongChain(uint256 chainId);
    error HookVanityBad(address predicted);
    error PredictMismatch(string what, address got, address want);
    error SizeOverEip170(string what, uint256 size);
    error MissingEnv(string name);
    error NonceMoved(uint64 expected, uint64 got);

    function run() external {
        if (block.chainid != CHAIN_ROBINHOOD) revert WrongChain(block.chainid);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address custody = vm.envOr("CUSTODY_ADDRESS", SAFE_DEFAULT);
        bytes32 hookSalt = vm.envBytes32("HOOK_CREATE2_SALT");
        if (hookSalt == bytes32(0)) revert MissingEnv("HOOK_CREATE2_SALT");

        StonkzExpressFactory express = StonkzExpressFactory(EXPRESS);
        StonkzFeeHook liveHook = StonkzFeeHook(payable(LIVE_HOOK));
        address treasury = liveHook.protocolTreasury();
        IPoolManager pm = express.poolManager();

        uint64 n = uint64(vm.getNonce(deployer));
        address govPred = vm.computeCreateAddress(deployer, n);

        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(StonkzFeeHook).creationCode, abi.encode(pm, treasury, ICTOGovernor(govPred), deployer)
            )
        );
        address hookPred = HookVanity.predict(CREATE2_FACTORY, hookSalt, initHash);
        if (!HookVanity.matches(hookPred)) revert HookVanityBad(hookPred);

        console2.log("=== HOOK-FEE EXPRESS BROADCAST (settlement DEFERRED) ===");
        console2.log("deployer", deployer);
        console2.log("nonce", n);
        console2.log("balance wei", deployer.balance);
        console2.log("custody", custody);
        console2.log("pm (adapter)", address(pm));
        console2.log("treasury", treasury);
        console2.log("govPred", govPred);
        console2.log("hookPred", hookPred);
        console2.logBytes32(initHash);
        console2.logBytes32(hookSalt);

        // Optional pin: refuse if nonce changed after mining (set EXPECT_NONCE).
        uint64 expectNonce = uint64(vm.envOr("EXPECT_NONCE", uint256(n)));
        if (n != expectNonce) revert NonceMoved(expectNonce, n);

        vm.startBroadcast(pk);

        CTOGovernor gov = new CTOGovernor();
        if (address(gov) != govPred) revert PredictMismatch("gov", address(gov), govPred);

        StonkzFeeHook newHook =
            new StonkzFeeHook{salt: hookSalt}(pm, treasury, ICTOGovernor(address(gov)), deployer);
        if (address(newHook) != hookPred) revert PredictMismatch("hook", address(newHook), hookPred);
        newHook.validateHookAddress(address(newHook));

        gov.setRegistry(newHook);
        newHook.transferOwnership(custody);

        vm.stopBroadcast();

        if (address(newHook).code.length > EIP170_MAX) {
            revert SizeOverEip170("StonkzFeeHook", address(newHook).code.length);
        }
        if (address(gov).code.length > EIP170_MAX) {
            revert SizeOverEip170("CTOGovernor", address(gov).code.length);
        }

        console2.log("--- deployed ---");
        console2.log("CTOGovernor", address(gov));
        console2.log("StonkzFeeHook", address(newHook));
        console2.log("hook.owner", newHook.owner());
        console2.log("hook.canonManager", address(newHook.canonManager()));
        console2.log("hook.HOOK_FLAGS", uint256(newHook.HOOK_FLAGS()));
        console2.log("gov.registry", address(gov.registry()));
        console2.log("hook.code.length", address(newHook).code.length);
        console2.log("gov.code.length", address(gov).code.length);

        console2.log("--- SAFE PAYLOADS (custody; settlement deferred) ---");
        console2.log("1) Express.setHook(newHook)");
        console2.log("  to", EXPRESS);
        console2.logBytes(abi.encodeWithSelector(express.setHook.selector, address(newHook)));
        console2.log("2) Express.setGovernor(newGovernor)");
        console2.log("  to", EXPRESS);
        console2.logBytes(abi.encodeWithSelector(express.setGovernor.selector, address(gov)));
        console2.log("DEFERRED: LadderSettlement + setSettlementRef + adapter.setAuthorized");
        console2.log("=== BROADCAST COMPLETE - execute Safe setHook + setGovernor ===");
    }

    /// @notice Offline: print initCodeHash + govPred for current nonce (no broadcast).
    function prepareMine() external view {
        if (block.chainid != CHAIN_ROBINHOOD) revert WrongChain(block.chainid);
        address deployer = vm.envOr("DEPLOYER", AUGUST_DEPLOYER);
        StonkzExpressFactory express = StonkzExpressFactory(EXPRESS);
        StonkzFeeHook liveHook = StonkzFeeHook(payable(LIVE_HOOK));
        uint64 n = uint64(vm.getNonce(deployer));
        address govPred = vm.computeCreateAddress(deployer, n);
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(StonkzFeeHook).creationCode,
                abi.encode(express.poolManager(), liveHook.protocolTreasury(), ICTOGovernor(govPred), deployer)
            )
        );
        console2.log("nonce", n);
        console2.log("govPred", govPred);
        console2.log("initCodeHash");
        console2.logBytes32(initHash);
        console2.log("CREATE2_FACTORY", CREATE2_FACTORY);
        console2.log("HOOK_FLAGS", uint256(HookVanity.HOOK_FLAGS));
    }
}
