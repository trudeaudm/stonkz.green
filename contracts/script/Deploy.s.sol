// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IPoolManager as ICanonPM} from "@v4-core/src/interfaces/IPoolManager.sol";

import {DeployControls} from "../src/DeployControls.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {V4Adapter} from "../src/v4/V4Adapter.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {HookVanity} from "../src/HookVanity.sol";
import {FeeLockerV2} from "../src/FeeLockerV2.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";
import {LadderSettlement} from "../src/ladder/LadderSettlement.sol";
import {StonkzVault} from "../src/vault/StonkzVault.sol";
import {VaultConstants} from "../src/vault/VaultConstants.sol";
import {StonkzExpressFactory} from "../src/StonkzExpressFactory.sol";
import {StonkzLadderFactory} from "../src/ladder/StonkzLadderFactory.sol";

/// @dev Minimal ERC-20 surface for stand-in validation (docs/03 GENESIS VIA PLATFORM).
interface IERC20StandInCheck {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @title DeploySoftLaunchGuard — RIDER A soft-launch assertion shared by deploy paths
abstract contract DeploySoftLaunchGuard is Script {
    function _assertSoftLaunchGate(DeployControls factory, address expectedDeployer) internal view {
        factory.assertSoftLaunchGate(expectedDeployer);
        console2.log("soft-launch gate OK", address(factory), expectedDeployer);
    }
}

/// @title Deploy — official full-manifest deploy (docs/03 GENESIS VIA PLATFORM + V4-CANON)
/// @notice Binds to Robinhood PoolManager via V4Adapter. Hook CREATE2-mined 0x4663+0x088.
///         NO StonkzToken deploy/mint — stonkzRef is a stand-in ERC-20 INPUT (repoint at genesis).
///         NO MockPoolManager in the official address book.
///
/// ENV (required for live/fork broadcast):
///   PRIVATE_KEY          — deployer key (env only; never a file)
///   CUSTODY_ADDRESS      — ownership-transfer target (Safe); NOT a mint destination
///   TREASURY_ADDRESS     — StonkzFeeHook protocolTreasury
///   HOOK_CREATE2_SALT    — from hook-vanity-mine.mjs --mode eoa
///   STONKZ_REF_ADDRESS   — stand-in ERC-20 on 4663 (code + totalSupply/balanceOf/decimals)
/// Optional:
///   ETH_REF_PRICE_WAD    — pair-wei/STONKZ; default 2.5e11. Formula: 0.001e18 / spotEthUsd
///   PAIR_TOKEN, USDG_ADDRESS, FORK, ADDRESS_BOOK_PATH
contract Deploy is DeploySoftLaunchGuard {
    using stdJson for string;

    uint256 internal constant CHAIN_ROBINHOOD = 4663;
    uint256 internal constant CHAIN_ANVIL = 31337;

    address internal constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant UNIVERSAL_ROUTER = 0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 internal constant REF_ETH = 2.5e11;
    uint256 internal constant REF_USDG = 1e15;

    error WrongChain(uint256 chainId);
    error MissingEnv(string name);
    error RefPriceMismatch(address pair, uint256 got, uint256 want);
    error WiringFailed(string what);
    error ExternalMissing(string what, address addr);
    error HookVanityBad(address predicted);
    error PredictMismatch(string what, address got, address want);
    error OwnershipNotTransferred(string what, address owner, address want);
    error StonkzRefInvalid(address ref);

    struct Book {
        address stonkzRef; // stand-in INPUT — never minted by this script
        address poolManager;
        address v4Adapter;
        address governor;
        address hook;
        address feeLocker;
        address accumulator;
        address settlement;
        address vault;
        address express;
        address ladder;
        address universalRouter;
        address permit2;
    }

    function run() external {
        _assertChainAllowed();
        vm.txGasPrice(60_000_000);

        address custody = vm.envAddress("CUSTODY_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address stonkzRef = vm.envAddress("STONKZ_REF_ADDRESS");
        address pairToken = vm.envOr("PAIR_TOKEN", address(0));
        address usdg = vm.envOr("USDG_ADDRESS", address(0));
        if (custody == address(0)) revert MissingEnv("CUSTODY_ADDRESS");
        if (treasury == address(0)) revert MissingEnv("TREASURY_ADDRESS");
        if (stonkzRef == address(0)) revert MissingEnv("STONKZ_REF_ADDRESS");
        _assertStonkzRef(stonkzRef);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        string memory bookPath = vm.envOr("ADDRESS_BOOK_PATH", string("../deploys/official/addresses.json"));
        Book memory book = _loadBook(bookPath);
        book.stonkzRef = stonkzRef;
        book.poolManager = RH_POOL_MANAGER;
        book.universalRouter = UNIVERSAL_ROUTER;
        book.permit2 = PERMIT2;

        _assertExternals();

        console2.log("Deploy chainId", block.chainid);
        console2.log("Deployer", deployer);
        console2.log("Custody (ownership only)", custody);
        console2.log("Treasury", treasury);
        console2.log("stonkzRef stand-in", stonkzRef);
        console2.log("RH PoolManager", RH_POOL_MANAGER);

        bool deployAdapter = !_hasCode(book.v4Adapter);
        bool deployGov = !_hasCode(book.governor);
        bool deployHook = !_hasCode(book.hook);

        bytes32 hookSalt;
        address hookPredicted;
        if (deployHook) {
            hookSalt = vm.envBytes32("HOOK_CREATE2_SALT");
            if (hookSalt == bytes32(0)) revert MissingEnv("HOOK_CREATE2_SALT");

            (address adapterPred, address govPred) =
                _predictAdapterGov(deployer, deployAdapter, deployGov, book);
            bytes32 initHash = _hookInitCodeHash(adapterPred, treasury, govPred);
            hookPredicted = HookVanity.predict(deployer, hookSalt, initHash);
            if (!HookVanity.matches(hookPredicted)) revert HookVanityBad(hookPredicted);
            console2.log("hook initCodeHash");
            console2.logBytes32(initHash);
            console2.log("hook predicted", hookPredicted);
        }

        vm.startBroadcast(pk);

        // 1) V4Adapter around RH singleton — never deploy MockPoolManager / StonkzToken
        if (deployAdapter) {
            book.v4Adapter = address(new V4Adapter(ICanonPM(RH_POOL_MANAGER)));
            console2.log("deployed V4Adapter", book.v4Adapter);
        } else {
            console2.log("skip V4Adapter", book.v4Adapter);
        }
        IPoolManager pm = IPoolManager(book.v4Adapter);

        // 2) CTO + hook + registry
        if (deployGov) {
            book.governor = address(new CTOGovernor());
            console2.log("deployed CTOGovernor", book.governor);
        } else {
            console2.log("skip CTOGovernor", book.governor);
        }

        if (deployHook) {
            book.hook = address(
                new StonkzFeeHook{salt: hookSalt}(pm, treasury, ICTOGovernor(book.governor))
            );
            if (book.hook != hookPredicted) revert PredictMismatch("hook", book.hook, hookPredicted);
            StonkzFeeHook(payable(book.hook)).validateHookAddress(book.hook);
            StonkzFeeHook(payable(book.hook)).bindCanonManager(ICanonPM(RH_POOL_MANAGER));
            console2.log("deployed StonkzFeeHook", book.hook);
        } else {
            console2.log("skip StonkzFeeHook", book.hook);
            if (address(StonkzFeeHook(payable(book.hook)).canonManager()) != RH_POOL_MANAGER) {
                StonkzFeeHook(payable(book.hook)).bindCanonManager(ICanonPM(RH_POOL_MANAGER));
            }
        }

        if (address(CTOGovernor(book.governor).registry()) == address(0)) {
            CTOGovernor(book.governor).setRegistry(StonkzFeeHook(payable(book.hook)));
        }

        // 3) Fee locker + buyback accumulator (stonkz4663 slot = stand-in until genesis repoint)
        if (!_hasCode(book.feeLocker)) {
            book.feeLocker = address(new FeeLockerV2(pm, StonkzFeeHook(payable(book.hook))));
            console2.log("deployed FeeLockerV2", book.feeLocker);
        } else {
            console2.log("skip FeeLockerV2", book.feeLocker);
        }

        if (!_hasCode(book.accumulator)) {
            book.accumulator = address(new BuybackAccumulator(pairToken, book.stonkzRef, address(0)));
            console2.log("deployed BuybackAccumulator", book.accumulator);
        } else {
            console2.log("skip BuybackAccumulator", book.accumulator);
        }

        // 4) Ladder settlement + stamps
        if (!_hasCode(book.settlement)) {
            book.settlement = address(new LadderSettlement(pm, StonkzFeeHook(payable(book.hook)), pairToken));
            console2.log("deployed LadderSettlement", book.settlement);
        } else {
            console2.log("skip LadderSettlement", book.settlement);
        }
        LadderSettlement(payable(book.settlement)).setStonkzRef(book.stonkzRef);
        LadderSettlement(payable(book.settlement)).setFeeLocker(FeeLockerV2(book.feeLocker));

        // 5) Vault
        if (!_hasCode(book.vault)) {
            book.vault = address(new StonkzVault(VaultConstants.LAUNCH_RATE_SECONDS_PER_BPS, 1, 10_000));
            console2.log("deployed StonkzVault", book.vault);
        } else {
            console2.log("skip StonkzVault", book.vault);
        }

        // 6) Express factory (stonkzRef = stand-in)
        if (!_hasCode(book.express)) {
            book.express = address(
                new StonkzExpressFactory(
                    pm,
                    FeeLockerV2(book.feeLocker),
                    StonkzFeeHook(payable(book.hook)),
                    BuybackAccumulator(payable(book.accumulator)),
                    CTOGovernor(book.governor),
                    pairToken,
                    book.stonkzRef
                )
            );
            console2.log("deployed StonkzExpressFactory", book.express);
        } else {
            console2.log("skip StonkzExpressFactory", book.express);
        }

        // 7) Ladder factory + vaultRef + optional USDG ref
        if (!_hasCode(book.ladder)) {
            book.ladder = address(new StonkzLadderFactory());
            console2.log("deployed StonkzLadderFactory", book.ladder);
        } else {
            console2.log("skip StonkzLadderFactory", book.ladder);
        }
        StonkzLadderFactory(book.ladder).setVaultRef(book.vault);
        if (usdg != address(0)) {
            StonkzLadderFactory(book.ladder).setStonkzRefPrice(usdg, REF_USDG);
        }
        if (pairToken != address(0) && pairToken != usdg) {
            StonkzLadderFactory(book.ladder).setStonkzRefPrice(pairToken, REF_USDG);
        }

        uint256 ethRef = vm.envOr("ETH_REF_PRICE_WAD", REF_ETH);
        StonkzExpressFactory(book.express).setStonkzRefPrice(address(0), ethRef);
        StonkzLadderFactory(book.ladder).setStonkzRefPrice(address(0), ethRef);
        console2.log("ETH stonkzRefPriceWad", ethRef);

        // 8) Ownership → custody Safe (ownership only — no token mint)
        DeployControls(book.express).transferOwnership(custody);
        DeployControls(book.ladder).transferOwnership(custody);
        StonkzFeeHook(payable(book.hook)).transferOwnership(custody);
        LadderSettlement(payable(book.settlement)).transferOwnership(custody);
        StonkzVault(book.vault).transferOwnership(custody);
        console2.log("ownership transferred to custody", custody);

        vm.stopBroadcast();

        _assertWiring(book, deployer, custody, pairToken, usdg, ethRef);
        _writeBook(bookPath, book, deployer, custody, treasury, pairToken, usdg);

        console2.log("=== DEPLOY COMPLETE ===");
        console2.log("stonkzRef stand-in", book.stonkzRef);
        console2.log("V4Adapter", book.v4Adapter);
        console2.log("StonkzFeeHook", book.hook);
        console2.log("ExpressFactory", book.express);
        console2.log("LadderFactory", book.ladder);
        console2.log("address book", bookPath);
    }

    /// @notice Offline helper: log hook initCodeHash for the miner without broadcasting.
    function prepareHookInitCodeHash() external {
        _assertChainAllowed();
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        string memory bookPath = vm.envOr("ADDRESS_BOOK_PATH", string("../deploys/official/addresses.json"));
        Book memory book = _loadBook(bookPath);

        bool deployAdapter = !_hasCode(book.v4Adapter);
        bool deployGov = !_hasCode(book.governor);
        (address adapterPred, address govPred) = _predictAdapterGov(deployer, deployAdapter, deployGov, book);

        bytes32 initHash = _hookInitCodeHash(adapterPred, treasury, govPred);
        console2.log("deployer", deployer);
        console2.log("adapterPred", adapterPred);
        console2.log("govPred", govPred);
        console2.logBytes32(initHash);
        console2.log("mine: node contracts/scripts/hook-vanity-mine.mjs --mode eoa --deployer", deployer);
    }

    function _hookInitCodeHash(address adapter, address treasury, address gov) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                type(StonkzFeeHook).creationCode, abi.encode(IPoolManager(adapter), treasury, ICTOGovernor(gov))
            )
        );
    }

    /// @dev CREATE order: adapter → governor → hook(CREATE2). No protocol token deploy.
    function _predictAdapterGov(address deployer, bool deployAdapter, bool deployGov, Book memory book)
        internal
        view
        returns (address adapterPred, address govPred)
    {
        uint64 nonce = uint64(vm.getNonce(deployer));
        if (deployAdapter) {
            adapterPred = vm.computeCreateAddress(deployer, nonce);
            nonce += 1;
        } else {
            adapterPred = book.v4Adapter;
        }
        if (deployGov) {
            govPred = vm.computeCreateAddress(deployer, nonce);
        } else {
            govPred = book.governor;
        }
    }

    function _assertChainAllowed() internal view {
        uint256 id = block.chainid;
        if (id == CHAIN_ROBINHOOD) return;
        bool fork = vm.envOr("FORK", false);
        if (id == CHAIN_ANVIL && fork) return;
        revert WrongChain(id);
    }

    function _assertExternals() internal view {
        if (RH_POOL_MANAGER.code.length == 0) revert ExternalMissing("PoolManager", RH_POOL_MANAGER);
        if (UNIVERSAL_ROUTER.code.length == 0) revert ExternalMissing("UniversalRouter", UNIVERSAL_ROUTER);
        if (PERMIT2.code.length == 0) revert ExternalMissing("Permit2", PERMIT2);
    }

    /// @dev Stand-in must have code and answer totalSupply / balanceOf / decimals.
    function _assertStonkzRef(address ref) internal view {
        if (ref == address(0) || ref.code.length == 0) revert StonkzRefInvalid(ref);
        try IERC20StandInCheck(ref).totalSupply() returns (uint256) {}
        catch {
            revert StonkzRefInvalid(ref);
        }
        try IERC20StandInCheck(ref).balanceOf(address(0)) returns (uint256) {}
        catch {
            revert StonkzRefInvalid(ref);
        }
        try IERC20StandInCheck(ref).decimals() returns (uint8) {}
        catch {
            revert StonkzRefInvalid(ref);
        }
    }

    function _hasCode(address a) internal view returns (bool) {
        return a != address(0) && a.code.length > 0;
    }

    function _loadBook(string memory path) internal view returns (Book memory b) {
        b.poolManager = RH_POOL_MANAGER;
        b.universalRouter = UNIVERSAL_ROUTER;
        b.permit2 = PERMIT2;
        if (!vm.exists(path)) return b;
        string memory raw = vm.readFile(path);
        b.stonkzRef = _readAddr(raw, ".contracts.StonkzRefStandIn");
        b.v4Adapter = _readAddr(raw, ".contracts.V4Adapter");
        b.governor = _readAddr(raw, ".contracts.CTOGovernor");
        b.hook = _readAddr(raw, ".contracts.StonkzFeeHook");
        b.feeLocker = _readAddr(raw, ".contracts.FeeLockerV2");
        b.accumulator = _readAddr(raw, ".contracts.BuybackAccumulator");
        b.settlement = _readAddr(raw, ".contracts.LadderSettlement");
        b.vault = _readAddr(raw, ".contracts.StonkzVault");
        b.express = _readAddr(raw, ".contracts.StonkzExpressFactory");
        b.ladder = _readAddr(raw, ".contracts.StonkzLadderFactory");
    }

    function _readAddr(string memory raw, string memory key) internal view returns (address a) {
        bytes memory data = vm.parseJson(raw, key);
        if (data.length == 0) return address(0);
        a = abi.decode(data, (address));
    }

    function _writeBook(
        string memory path,
        Book memory book,
        address deployer,
        address custody,
        address treasury,
        address pairToken,
        address usdg
    ) internal {
        string memory root = "book";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeString(root, "mode", block.chainid == CHAIN_ROBINHOOD ? "official" : "fork");
        vm.serializeAddress(root, "deployer", deployer);

        string memory contracts = "contracts";
        vm.serializeAddress(contracts, "StonkzRefStandIn", book.stonkzRef);
        vm.serializeAddress(contracts, "PoolManager", RH_POOL_MANAGER);
        vm.serializeAddress(contracts, "V4Adapter", book.v4Adapter);
        vm.serializeAddress(contracts, "UniversalRouter", UNIVERSAL_ROUTER);
        vm.serializeAddress(contracts, "Permit2", PERMIT2);
        vm.serializeAddress(contracts, "CTOGovernor", book.governor);
        vm.serializeAddress(contracts, "StonkzFeeHook", book.hook);
        vm.serializeAddress(contracts, "FeeLockerV2", book.feeLocker);
        vm.serializeAddress(contracts, "BuybackAccumulator", book.accumulator);
        vm.serializeAddress(contracts, "LadderSettlement", book.settlement);
        vm.serializeAddress(contracts, "StonkzVault", book.vault);
        vm.serializeAddress(contracts, "StonkzExpressFactory", book.express);
        string memory contractsJson = vm.serializeAddress(contracts, "StonkzLadderFactory", book.ladder);

        string memory config = "config";
        vm.serializeAddress(config, "custody", custody);
        vm.serializeAddress(config, "treasury", treasury);
        vm.serializeAddress(config, "pairToken", pairToken);
        vm.serializeAddress(config, "usdg", usdg);
        vm.serializeAddress(config, "stonkzRefStandIn", book.stonkzRef);
        vm.serializeString(config, "refPriceEthWad", "250000000000");
        vm.serializeString(config, "refPriceUsdgWad", "1000000000000000");
        string memory configJson = vm.serializeString(
            config,
            "poolManagerNote",
            "Robinhood PoolManager singleton 0x8366a39C via V4Adapter; MockPoolManager not in official manifest; no StonkzToken in manifest"
        );

        string memory wiring = "wiring";
        vm.serializeBool(wiring, "vaultRef", true);
        vm.serializeBool(wiring, "settlementStonkzRef", true);
        vm.serializeBool(wiring, "settlementFeeLocker", true);
        vm.serializeBool(wiring, "govRegistry", true);
        vm.serializeBool(wiring, "softLaunchExpress", true);
        vm.serializeBool(wiring, "softLaunchLadder", true);
        vm.serializeBool(wiring, "hookFlagsValidated", true);
        vm.serializeBool(wiring, "canonManagerBound", true);
        vm.serializeBool(wiring, "ownershipToCustody", true);
        string memory wiringJson = vm.serializeBool(wiring, "stonkzRefIsStandIn", true);

        string memory templates = "templates";
        vm.serializeString(templates, "StonkzDirectListing", "factory-CREATE2-via-StonkzExpressFactory");
        vm.serializeString(templates, "StonkzLadderAuction", "factory-via-StonkzLadderFactory");
        string memory templatesJson =
            vm.serializeString(templates, "DeployControls", "inherited-by-both-factories");

        vm.serializeString(root, "contracts", contractsJson);
        vm.serializeString(root, "config", configJson);
        vm.serializeString(root, "wiring", wiringJson);
        string memory finalJson = vm.serializeString(root, "templates", templatesJson);
        vm.writeJson(finalJson, path);
    }

    function _assertWiring(
        Book memory book,
        address deployer,
        address custody,
        address pairToken,
        address usdg,
        uint256 ethRef
    ) internal view {
        if (book.poolManager != RH_POOL_MANAGER) revert WiringFailed("poolManager pin");
        if (!_hasCode(book.v4Adapter)) revert WiringFailed("v4Adapter");
        if (address(V4Adapter(payable(book.v4Adapter)).manager()) != RH_POOL_MANAGER) {
            revert WiringFailed("adapter.manager");
        }
        _assertStonkzRef(book.stonkzRef);

        _assertSoftLaunchGate(DeployControls(book.express), deployer);
        _assertSoftLaunchGate(DeployControls(book.ladder), deployer);

        StonkzExpressFactory express = StonkzExpressFactory(book.express);
        if (express.stonkzRef() != book.stonkzRef) revert WiringFailed("express.stonkzRef");
        if (address(express.hook()) != book.hook) revert WiringFailed("express.hook");
        if (address(express.poolManager()) != book.v4Adapter) revert WiringFailed("express.pm=adapter");

        StonkzLadderFactory ladder = StonkzLadderFactory(book.ladder);
        if (ladder.vaultRef() != book.vault) revert WiringFailed("ladder.vaultRef");

        LadderSettlement settlement = LadderSettlement(payable(book.settlement));
        if (settlement.stonkzRef() != book.stonkzRef) revert WiringFailed("settlement.stonkzRef");
        if (address(settlement.feeLocker()) != book.feeLocker) revert WiringFailed("settlement.feeLocker");

        if (address(CTOGovernor(book.governor).registry()) != book.hook) revert WiringFailed("gov.registry");

        StonkzFeeHook hook = StonkzFeeHook(payable(book.hook));
        if (!HookVanity.matches(book.hook)) revert HookVanityBad(book.hook);
        if (address(hook.canonManager()) != RH_POOL_MANAGER) revert WiringFailed("hook.canonManager");
        if (address(hook.poolManager()) != book.v4Adapter) revert WiringFailed("hook.poolManager");

        uint256 ethExpress = express.stonkzRefPriceWad(address(0));
        uint256 ethLadder = ladder.stonkzRefPriceWad(address(0));
        if (ethExpress != ethRef) revert RefPriceMismatch(address(0), ethExpress, ethRef);
        if (ethLadder != ethRef) revert RefPriceMismatch(address(0), ethLadder, ethRef);

        if (usdg != address(0)) {
            uint256 u = ladder.stonkzRefPriceWad(usdg);
            if (u != REF_USDG) revert RefPriceMismatch(usdg, u, REF_USDG);
        }
        if (pairToken != address(0)) {
            uint256 p = express.stonkzRefPriceWad(pairToken);
            if (p != REF_USDG) revert RefPriceMismatch(pairToken, p, REF_USDG);
        }

        BuybackAccumulator acc = BuybackAccumulator(payable(book.accumulator));
        if (acc.stonkz4663() != book.stonkzRef) revert WiringFailed("accumulator.stonkzRef");

        if (DeployControls(book.express).owner() != custody) {
            revert OwnershipNotTransferred("express", DeployControls(book.express).owner(), custody);
        }
        if (DeployControls(book.ladder).owner() != custody) {
            revert OwnershipNotTransferred("ladder", DeployControls(book.ladder).owner(), custody);
        }
        if (hook.owner() != custody) revert OwnershipNotTransferred("hook", hook.owner(), custody);
        if (settlement.owner() != custody) {
            revert OwnershipNotTransferred("settlement", settlement.owner(), custody);
        }
        if (StonkzVault(book.vault).owner() != custody) {
            revert OwnershipNotTransferred("vault", StonkzVault(book.vault).owner(), custody);
        }
    }
}
