// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {FeeLockerV2} from "../src/FeeLockerV2.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {StonkzExpressFactory} from "../src/StonkzExpressFactory.sol";
import {DeployControls} from "../src/DeployControls.sol";

/// @title DeployExpressV4 — mint-geometry fix factory (reads ctor args from live Express V3)
/// @notice V3 is NOT touched. New factory stamps corrected StonkzDirectListing creation code.
///
/// ENV:
///   PRIVATE_KEY     - required for --broadcast only; dry-run uses --sender
///   CUSTODY_ADDRESS - Safe for ownership transfer (Phase 2); default August Safe
///   SOURCE_EXPRESS  - optional; default Express V3 0xb5105a1954e0f4045CB902606afB4178F471A338
///   DO_TRANSFER     - if "true" and broadcasting, transferOwnership(custody) after deploy
///
/// Phase 1 dry-run:
///   forge script script/DeployExpressV4.s.sol:DeployExpressV4 \
///     --rpc-url $RPC --sender 0x8F5077eC52543d6393F483dC2B958Bf8Cad2d232 -vvvv
/// Phase 2: same + --broadcast + DO_TRANSFER=true (await explicit BROADCAST GO)
contract DeployExpressV4 is Script {
    uint256 internal constant CHAIN_ROBINHOOD = 4663;
    uint256 internal constant EIP170_MAX = 24_576;

    address internal constant SOURCE_EXPRESS_DEFAULT = 0xb5105a1954e0f4045CB902606afB4178F471A338;
    address internal constant SAFE_DEFAULT = 0x9D116B03FA6eB7F02c232670Bc083530609c5572;
    address internal constant AUGUST_DEPLOYER = 0x8F5077eC52543d6393F483dC2B958Bf8Cad2d232;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    error WrongChain(uint256 chainId);
    error SizeOverEip170(string what, uint256 size);
    error OwnerMismatch(address got, address want);
    error PredictMismatch(address got, address want);

    function run() external {
        if (block.chainid != CHAIN_ROBINHOOD) revert WrongChain(block.chainid);

        address sourceExpress = vm.envOr("SOURCE_EXPRESS", SOURCE_EXPRESS_DEFAULT);
        address custody = vm.envOr("CUSTODY_ADDRESS", SAFE_DEFAULT);
        bool doTransfer = vm.envOr("DO_TRANSFER", false);

        StonkzExpressFactory src = StonkzExpressFactory(sourceExpress);

        IPoolManager poolManager = src.poolManager();
        FeeLockerV2 feeLocker = src.feeLocker();
        StonkzFeeHook hook = src.hook();
        BuybackAccumulator accumulator = src.accumulator();
        CTOGovernor ctoGovernor = src.ctoGovernor();
        address pairToken = src.pairToken();
        address sideTokenRef = src.sideTokenRef();

        console2.log("=== EXPRESS V4 DEPLOY - constructor args (from V3 factory) ===");
        console2.log("SOURCE (V3) factory", sourceExpress);
        console2.log("poolManager (V4Adapter)", address(poolManager));
        console2.log("feeLocker", address(feeLocker));
        console2.log("hook", address(hook));
        console2.log("accumulator", address(accumulator));
        console2.log("ctoGovernor", address(ctoGovernor));
        console2.log("pairToken", pairToken);
        console2.log("sideTokenRef", sideTokenRef);
        console2.log("SOURCE owner", src.owner());
        console2.log("custody (Safe target)", custody);

        // Safe payloads needed after deploy (Phase 2) — print for operator.
        console2.log("=== SAFE PAYLOAD HINTS (Phase 2, do NOT execute in Phase 1) ===");
        console2.log("setRefPools: copy identical args from V3 (same PM + pool ids + ethIs0 + stableDec)");
        try src.currentEthUsdWad() returns (uint256 ethUsd) {
            uint256 refHint = FixedPointMathLib.mulDiv(1e18, 1e18, ethUsd);
            console2.log("currentEthUsdWad (live)", ethUsd);
            console2.log("setRefPrice hint (1e36/ethUsd) for USDG/ETH", refHint);
            console2.log("V3 stamped refPriceWad USDG/ETH", src.refPriceWad(USDG, address(0)));
            console2.log("NOTE: recompute setRefPrice at payload time from currentEthUsdWad");
        } catch {
            console2.log("currentEthUsdWad unavailable on source (ref pools unset?)");
        }
        console2.log("ethUsdStampBandBps on source", src.ethUsdStampBandBps());
        console2.log("band is ctor-seeded at 200 on fresh factory; setEthUsdStampBandBps only if changing");

        address deployer;
        uint256 pk;
        bool haveKey;
        try vm.envUint("PRIVATE_KEY") returns (uint256 k) {
            pk = k;
            deployer = vm.addr(pk);
            haveKey = true;
        } catch {
            deployer = vm.envOr("DEPLOYER_ADDRESS", AUGUST_DEPLOYER);
            haveKey = false;
        }
        console2.log("deployer", deployer);
        console2.log("havePrivateKey", haveKey);

        uint64 nonce = uint64(vm.getNonce(deployer));
        address predictedFactory = vm.computeCreateAddress(deployer, nonce);
        address predictedPtr0 = vm.computeCreateAddress(predictedFactory, 1);
        address predictedPtr1 = vm.computeCreateAddress(predictedFactory, 2);

        console2.log("=== PREDICTIONS (deployer nonce", nonce, ") ===");
        console2.log("predicted factory", predictedFactory);
        console2.log("predicted listingCreationPtr0", predictedPtr0);
        console2.log("predicted listingCreationPtr1", predictedPtr1);

        uint256 bal = deployer.balance;
        console2.log("deployer balance wei", bal);

        bool broadcasting = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
            || vm.isContext(VmSafe.ForgeContext.ScriptResume);

        if (broadcasting) {
            if (!haveKey) revert("PRIVATE_KEY required for broadcast");
            console2.log("=== BROADCAST MODE ===");
            vm.startBroadcast(pk);
        } else {
            console2.log("=== DRY-RUN / SIMULATION (no broadcast) ===");
            vm.startBroadcast(deployer);
        }

        StonkzExpressFactory neu = new StonkzExpressFactory(
            poolManager, feeLocker, hook, accumulator, ctoGovernor, pairToken, sideTokenRef
        );

        if (doTransfer && broadcasting) {
            DeployControls(address(neu)).transferOwnership(custody);
            console2.log("ownership transferred to", custody);
        }

        vm.stopBroadcast();

        if (address(neu) != predictedFactory) revert PredictMismatch(address(neu), predictedFactory);

        address ptr0 = neu.listingCreationPtr0();
        address ptr1 = neu.listingCreationPtr1();
        console2.log("=== DEPLOYED / SIMULATED ===");
        console2.log("factory", address(neu));
        console2.log("listingCreationPtr0", ptr0);
        console2.log("listingCreationPtr1", ptr1);

        uint256 factorySize = address(neu).code.length;
        uint256 ptr0Size = ptr0.code.length;
        uint256 ptr1Size = ptr1 == address(0) ? 0 : ptr1.code.length;
        console2.log("factory runtime size", factorySize);
        console2.log("ptr0 runtime size", ptr0Size);
        console2.log("ptr1 runtime size", ptr1Size);
        if (factorySize > EIP170_MAX) revert SizeOverEip170("factory", factorySize);
        if (ptr0Size > EIP170_MAX) revert SizeOverEip170("ptr0", ptr0Size);
        if (ptr1Size > EIP170_MAX) revert SizeOverEip170("ptr1", ptr1Size);
        console2.log("EIP-170: all under", EIP170_MAX);

        bool enabled = neu.deploysEnabled();
        uint256 allowCount = neu.allowlistCount();
        bool deployerAllowed = neu.isDeployerAllowed(deployer);
        address ownerNow = neu.owner();
        uint16 band = neu.ethUsdStampBandBps();
        console2.log("=== GATE STATE (fresh factory) ===");
        console2.log("owner", ownerNow);
        console2.log("deploysEnabled", enabled);
        console2.log("allowlistCount", allowCount);
        console2.log("isDeployerAllowed(deployer)", deployerAllowed);
        console2.log("ethUsdStampBandBps", band);
        require(enabled, "gate: deploysEnabled expected true");
        require(allowCount == 1, "gate: allowlistCount expected 1");
        require(deployerAllowed, "gate: deployer must be allowlisted");
        require(band == 200, "gate: ethUsdStampBandBps expected 200");
        require(ownerNow == deployer || (doTransfer && broadcasting && ownerNow == custody), "gate: owner");
        console2.log("soft-launch posture: CLOSED (deployer-only) - OK");

        if (doTransfer && broadcasting) {
            if (neu.owner() != custody) revert OwnerMismatch(neu.owner(), custody);
        }

        console2.log("=== PHASE NOTE ===");
        if (!broadcasting) {
            console2.log("DRY RUN complete. STOP - await explicit BROADCAST GO.");
            console2.log("Phase 2: --broadcast + DO_TRANSFER + Safe setRefPools + setRefPrice.");
            console2.log("NOTE: live V4Adapter is reused; setBreakNetting onlyOwner is source-only until adapter redeploy.");
        } else {
            console2.log("BROADCAST complete. Record tx from forge broadcast JSON.");
        }
    }
}
