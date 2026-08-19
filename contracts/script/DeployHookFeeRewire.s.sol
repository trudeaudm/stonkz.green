// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager as ICanonPM} from "@v4-core/src/interfaces/IPoolManager.sol";

import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {HookVanity} from "../src/HookVanity.sol";
import {FeeLockerV2} from "../src/FeeLockerV2.sol";
import {LadderSettlement} from "../src/ladder/LadderSettlement.sol";
import {StonkzExpressFactory} from "../src/StonkzExpressFactory.sol";
import {StonkzLadderFactory} from "../src/ladder/StonkzLadderFactory.sol";

/// @dev Live Express-V4 adapter surface (allowlist) — not the pre-allowlist V4Adapter.sol on this branch.
interface ILiveAdapter {
    function owner() external view returns (address);
    function manager() external view returns (address);
    function setAuthorized(address account, bool allowed) external;
}

/// @title DeployHookFeeRewire — Phase 1 dry-run for the pair-side fee fix (recon §6)
/// @notice NO broadcast unless `--broadcast` is passed (STOP: wait for BROADCAST GO).
///         Reads live constructor args, predicts addresses, logs EIP-170 sizes, gas, balances,
///         and every Safe payload for the rewire set:
///           new StonkzFeeHook (mined 0x4663 + 0x0CC)
///           + Express factory.setHook(newHook)
///           + new LadderSettlement (hook immutable)
///           + ladderFactory.setSettlementRef(newSettlement)
///           + new CTOGovernor (setRegistry one-shot) + factory.setGovernor
///
/// REUSED (do not redeploy): V4Adapter, FeeLockerV2, Express factory bytecode, listing
/// template, PoolManager, Vault, BuybackAccumulator.
///
/// ENV:
///   HOOK_CREATE2_SALT  - from hook-vanity-mine.mjs --mode eoa --deployer CREATE2_FACTORY
///                        (required to predict the mined hook address; optional to print hash)
///   DEPLOYER           - default August EOA 0x8F50…d232 (--sender should match)
///   CUSTODY_ADDRESS    - Safe; default 0x9D11…5572
///
/// Dry-run:
///   forge script script/DeployHookFeeRewire.s.sol:DeployHookFeeRewire \
///     --rpc-url $ROBINHOOD_RPC_URL --sender 0x8F5077eC52543d6393F483dC2B958Bf8Cad2d232 -vvvv
contract DeployHookFeeRewire is Script {
    uint256 internal constant CHAIN_ROBINHOOD = 4663;
    uint256 internal constant EIP170_MAX = 24_576;

    address internal constant EXPRESS = 0xEe2590c39E1485ed2F9cdaA684ab7B91d284E94a;
    address internal constant LADDER_FACTORY = 0xdfF96ADb478EB7C54ECf7a169C6B3205c7002676;
    address internal constant LIVE_HOOK = 0x4663c4c5Cb6F826d148cD38aDaF9157f483d0088;
    address internal constant LIVE_SETTLEMENT = 0x6b6E777d743A97010bf2C79E9F22A9A215c1a7E1;
    address internal constant LIVE_GOVERNOR = 0x3990070971595C49e1646eD5347252AB028449d0;
    address internal constant LIVE_ADAPTER = 0x97F2b8679E70962A56A56338f54A2073a37aAF6C;
    address internal constant LIVE_LOCKER = 0xf7e02D3F51Fe22Fa0428821552a087cFf07f0300;
    address internal constant LIVE_ACCUMULATOR = 0x100afE1947De681C71808Ce4b1554bEF50Adc8F1;
    address internal constant LIVE_VAULT = 0x6ff723f62C61292CDF776Edc76e0Da5ea6D5549c;
    address internal constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant AUGUST_DEPLOYER = 0x8F5077eC52543d6393F483dC2B958Bf8Cad2d232;
    address internal constant SAFE_DEFAULT = 0x9D116B03FA6eB7F02c232670Bc083530609c5572;

    error WrongChain(uint256 chainId);
    error HookVanityBad(address predicted);
    error SizeOverEip170(string what, uint256 size);

    function run() external {
        if (block.chainid != CHAIN_ROBINHOOD) revert WrongChain(block.chainid);

        address deployer = vm.envOr("DEPLOYER", AUGUST_DEPLOYER);
        address custody = vm.envOr("CUSTODY_ADDRESS", SAFE_DEFAULT);

        StonkzExpressFactory express = StonkzExpressFactory(EXPRESS);
        StonkzLadderFactory ladder = StonkzLadderFactory(LADDER_FACTORY);
        LadderSettlement liveSettlement = LadderSettlement(payable(LIVE_SETTLEMENT));
        StonkzFeeHook liveHook = StonkzFeeHook(payable(LIVE_HOOK));
        ILiveAdapter adapter = ILiveAdapter(LIVE_ADAPTER);

        address treasury = liveHook.protocolTreasury();
        IPoolManager pm = express.poolManager();
        address pairToken = express.pairToken();
        address sideTokenRef = express.sideTokenRef();
        address liveHookFromFactory = address(express.hook());
        address liveGovFromFactory = address(express.ctoGovernor());

        console2.log("=== HOOK-FEE REWIRE DRY-RUN (recon s6) - DO NOT BROADCAST ===");
        console2.log("chainId", block.chainid);
        console2.log("deployer", deployer);
        console2.log("deployer nonce", vm.getNonce(deployer));
        console2.log("deployer balance wei", deployer.balance);
        console2.log("custody Safe", custody);
        console2.log("CREATE2_FACTORY", CREATE2_FACTORY);

        console2.log("--- live reads ---");
        console2.log("express", EXPRESS);
        console2.log("express.owner", express.owner());
        console2.log("express.hook (live)", liveHookFromFactory);
        console2.log("express.hook pin", LIVE_HOOK);
        console2.log("express.ctoGovernor", liveGovFromFactory);
        console2.log("express.poolManager (adapter)", address(pm));
        console2.log("express.pairToken", pairToken);
        console2.log("express.sideTokenRef", sideTokenRef);
        console2.log("live hook.owner", liveHook.owner());
        console2.log("live hook.protocolTreasury", treasury);
        console2.log("live hook.canonManager", address(liveHook.canonManager()));
        console2.log("live hook.HOOK_FLAGS", uint256(liveHook.HOOK_FLAGS()));
        console2.log("ladderFactory", LADDER_FACTORY);
        console2.log("ladder.owner", ladder.owner());
        console2.log("ladder.settlementRef", ladder.settlementRef());
        console2.log("live settlement.hook", address(liveSettlement.hook()));
        console2.log("live settlement.poolManager", address(liveSettlement.poolManager()));
        console2.log("live settlement.pairToken", liveSettlement.pairToken());
        console2.log("live settlement.sideTokenRef", liveSettlement.sideTokenRef());
        console2.log("live settlement.feeLocker", address(liveSettlement.feeLocker()));
        console2.log("live settlement.owner", liveSettlement.owner());
        console2.log("adapter.owner", adapter.owner());
        console2.log("adapter.manager (PM)", address(adapter.manager()));

        console2.log("--- REUSED (not redeployed) ---");
        console2.log("V4Adapter", LIVE_ADAPTER);
        console2.log("FeeLockerV2", LIVE_LOCKER);
        console2.log("BuybackAccumulator", LIVE_ACCUMULATOR);
        console2.log("StonkzVault", LIVE_VAULT);
        console2.log("PoolManager", RH_POOL_MANAGER);
        console2.log("Express factory (setHook only; bytecode reused)", EXPRESS);
        console2.log("listing template / factory SSTORE2: UNCHANGED");

        uint64 n = uint64(vm.getNonce(deployer));
        address govPred = vm.computeCreateAddress(deployer, n);
        // txs: 0 governor, 1 hook CREATE2, 2 setRegistry, 3 settlement, then wiring
        address settlementPred = vm.computeCreateAddress(deployer, n + 3);

        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(StonkzFeeHook).creationCode,
                abi.encode(pm, treasury, ICTOGovernor(govPred), deployer)
            )
        );
        console2.log("--- hook mine ---");
        console2.log("predicted CTOGovernor (nonce)", govPred);
        console2.log("hook initCodeHash (adapter, treasury, govPred, deployer=owner)");
        console2.logBytes32(initHash);
        console2.log("HOOK_FLAGS target", uint256(HookVanity.HOOK_FLAGS));
        console2.log("mine:");
        console2.log(
            "  node contracts/scripts/hook-vanity-mine.mjs --mode eoa --deployer", CREATE2_FACTORY
        );
        console2.log("  --initCodeHash <hash above>");
        console2.log("expected effort ~2^30 hashes (16-bit 0x4663 + 14-bit 0x0CC); same as 0x088 mine");

        console2.log("--- EIP-170 (runtime size; creationCode logged, runtime after sim/deploy) ---");
        console2.log("StonkzFeeHook creationCode", type(StonkzFeeHook).creationCode.length);
        console2.log("CTOGovernor creationCode", type(CTOGovernor).creationCode.length);
        console2.log("LadderSettlement creationCode", type(LadderSettlement).creationCode.length);
        console2.log("EIP-170 max runtime 24576; confirm address(new).code.length after sim");

        address hookPred;
        bytes32 hookSalt = vm.envOr("HOOK_CREATE2_SALT", bytes32(0));
        bool haveSalt = hookSalt != bytes32(0);

        if (haveSalt) {
            hookPred = HookVanity.predict(CREATE2_FACTORY, hookSalt, initHash);
            if (!HookVanity.matches(hookPred)) revert HookVanityBad(hookPred);
            console2.log("hook predicted (0x4663 + 0x0CC)", hookPred);
        } else {
            console2.log("HOOK_CREATE2_SALT unset - hook address not predicted; mine then re-run");
        }

        console2.log("predicted LadderSettlement (nonce n+3)", settlementPred);

        console2.log("--- constructor args (new instances) ---");
        console2.log("StonkzFeeHook(pm=adapter, treasury, ctoGovernor=govPred, initialOwner=deployer)");
        console2.log("  pm", address(pm));
        console2.log("  treasury", treasury);
        console2.log("  ctoGovernor", govPred);
        console2.log("  initialOwner", deployer);
        console2.log("LadderSettlement(pm=adapter, hook=newHook, pairToken)");
        console2.log("  pm", address(pm));
        console2.log("  pairToken", pairToken);
        console2.log("  live settlement.pairToken", liveSettlement.pairToken());
        console2.log("CTOGovernor() - no args; setRegistry(newHook) one-shot from deployer");

        console2.log("--- SAFE PAYLOADS (custody 2-of-3; execute AFTER deployer txs) ---");
        if (haveSalt) {
            _logSafe("1) Express.setHook(newHook)", EXPRESS, abi.encodeWithSelector(express.setHook.selector, hookPred));
            _logSafe(
                "2) LadderFactory.setSettlementRef(newSettlement)",
                LADDER_FACTORY,
                abi.encodeWithSelector(ladder.setSettlementRef.selector, settlementPred)
            );
            _logSafe(
                "3) Express.setGovernor(newGovernor)",
                EXPRESS,
                abi.encodeWithSelector(express.setGovernor.selector, govPred)
            );
            _logSafe(
                "4) V4Adapter.setAuthorized(newSettlement, true)",
                LIVE_ADAPTER,
                abi.encodeWithSelector(adapter.setAuthorized.selector, settlementPred, true)
            );
        } else {
            console2.log("1) express.setHook(newHook)                 to", EXPRESS);
            console2.log("2) ladder.setSettlementRef(newSettlement)   to", LADDER_FACTORY);
            console2.log("3) express.setGovernor(newGovernor)         to", EXPRESS);
            console2.log("4) adapter.setAuthorized(newSettlement,true) to", LIVE_ADAPTER);
            console2.log("(re-run with HOOK_CREATE2_SALT for exact calldata)");
        }
        console2.log("Safe targets must be owned by custody:");
        console2.log("  express.owner == custody", express.owner() == custody);
        console2.log("  ladder.owner  == custody", ladder.owner() == custody);
        console2.log("  adapter.owner == custody", adapter.owner() == custody);

        console2.log("--- deployer txs (this script, after GO; not Safe) ---");
        console2.log("A) new CTOGovernor()");
        console2.log("B) new StonkzFeeHook{salt}(adapter, treasury, gov, deployer)");
        console2.log("C) gov.setRegistry(hook)");
        console2.log("D) new LadderSettlement(adapter, hook, pairToken)");
        console2.log("E) settlement.setSideTokenRef(sideTokenRef)");
        console2.log("F) settlement.setFeeLocker(live FeeLockerV2)");
        console2.log("G) hook.transferOwnership(custody)");
        console2.log("H) settlement.transferOwnership(custody)");
        console2.log("sideTokenRef", sideTokenRef);
        console2.log("feeLocker (reused)", LIVE_LOCKER);

        console2.log("--- existing lists ---");
        console2.log("MOONER/SDONK/T/BONZI keep LIVE_HOOK in PoolKey forever. This rewire is NEW lists only.");
        console2.log("Interim 0-fee unblock remains bindCanonManager on LIVE_HOOK (not this script).");

        if (haveSalt && vm.envOr("DO_SIM_DEPLOY", false)) {
            console2.log("--- simulating deploys (DO_SIM_DEPLOY=true; still no broadcast unless --broadcast) ---");
            uint256 gasHook;
            uint256 gasGov;
            uint256 gasSett;
            vm.startBroadcast();
            uint256 g0 = gasleft();
            CTOGovernor gov = new CTOGovernor();
            gasGov = g0 - gasleft();
            if (address(gov) != govPred) {
                console2.log("WARN gov address != pred (nonce moved)", address(gov), govPred);
            }
            g0 = gasleft();
            StonkzFeeHook newHook = new StonkzFeeHook{salt: hookSalt}(pm, treasury, ICTOGovernor(address(gov)), deployer);
            gasHook = g0 - gasleft();
            newHook.validateHookAddress(address(newHook));
            gov.setRegistry(newHook);
            g0 = gasleft();
            LadderSettlement settlement = new LadderSettlement(pm, newHook, pairToken);
            gasSett = g0 - gasleft();
            settlement.setSideTokenRef(sideTokenRef);
            settlement.setFeeLocker(FeeLockerV2(LIVE_LOCKER));
            newHook.transferOwnership(custody);
            settlement.transferOwnership(custody);
            vm.stopBroadcast();
            console2.log("sim governor", address(gov));
            console2.log("sim gov gas", gasGov);
            console2.log("sim hook", address(newHook));
            console2.log("sim hook gas", gasHook);
            console2.log("sim settlement", address(settlement));
            console2.log("sim settlement gas", gasSett);
            console2.log("sim hook.code.length", address(newHook).code.length);
            console2.log("sim settlement.code.length", address(settlement).code.length);
            console2.log("sim gov.code.length", address(gov).code.length);
            if (address(newHook).code.length > EIP170_MAX) revert SizeOverEip170("StonkzFeeHook", address(newHook).code.length);
            if (address(gov).code.length > EIP170_MAX) revert SizeOverEip170("CTOGovernor", address(gov).code.length);
            if (address(settlement).code.length > EIP170_MAX) {
                revert SizeOverEip170("LadderSettlement", address(settlement).code.length);
            }
        }

        console2.log("=== STOP: dry-run complete. No broadcast. Wait BROADCAST GO. ===");
    }

    function _logSafe(string memory label, address to, bytes memory data) internal pure {
        console2.log(label);
        console2.log("  to", to);
        console2.logBytes(data);
    }
}
