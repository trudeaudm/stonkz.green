// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {DeployControls} from "../src/DeployControls.sol";
import {StonkzToken} from "../src/StonkzToken.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {FeeLockerV2} from "../src/FeeLockerV2.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";
import {LadderSettlement} from "../src/ladder/LadderSettlement.sol";
import {StonkzVault} from "../src/vault/StonkzVault.sol";
import {VaultConstants} from "../src/vault/VaultConstants.sol";
import {StonkzExpressFactory} from "../src/StonkzExpressFactory.sol";
import {StonkzLadderFactory} from "../src/ladder/StonkzLadderFactory.sol";

/// @title DeploySoftLaunchGuard — RIDER A soft-launch assertion shared by deploy paths
abstract contract DeploySoftLaunchGuard is Script {
    /// @dev Call after each factory construct (or after intentional allowlist config).
    function _assertSoftLaunchGate(DeployControls factory, address expectedDeployer) internal view {
        factory.assertSoftLaunchGate(expectedDeployer);
        console2.log("soft-launch gate OK", address(factory), expectedDeployer);
    }
}

/// @title Deploy — official full-manifest deploy (docs/03 ONE DEPLOY 2026-08-10)
/// @notice Deploys STONKZ token + factories + settlement + hook + vault + wiring.
///         Keys NEVER on disk: PRIVATE_KEY / RPC from env only. David executes mainnet sends.
///
/// ENV (required for live/fork broadcast):
///   PRIVATE_KEY          — deployer key (env only; never a file)
///   CUSTODY_ADDRESS      — receives full 100M STONKZ supply
///   TREASURY_ADDRESS     — StonkzFeeHook protocolTreasury
/// Optional:
///   PAIR_TOKEN           — default address(0) = native ETH
///   USDG_ADDRESS         — if set, seeds Ladder factory USDG ref @ 1e15
///   FORK                 — "true" required when chainid is 31337; never for wrong live chains
///   ADDRESS_BOOK_PATH    — default ../deploys/official/addresses.json (from contracts/)
///
/// Gas (100ms Robinhood blocks): forge --gas-price 60000000 --priority-gas-price 0
///
/// RUN (fork proof, no mainnet key in chat):
///   $env:FORK="true"; forge script script/Deploy.s.sol:Deploy --rpc-url $env:ROBINHOOD_RPC_URL \
///     --broadcast --gas-price 60000000 --priority-gas-price 0
contract Deploy is DeploySoftLaunchGuard {
    using stdJson for string;

    uint256 internal constant CHAIN_ROBINHOOD = 4663;
    uint256 internal constant CHAIN_ANVIL = 31337;

    /// @dev Pair-wei per STONKZ, WAD — must match DeployControls birth defaults.
    uint256 internal constant REF_ETH = 2.5e11;
    uint256 internal constant REF_USDG = 1e15;

    error WrongChain(uint256 chainId);
    error MissingEnv(string name);
    error SoftLaunchBroken(string which);
    error RefPriceMismatch(address pair, uint256 got, uint256 want);
    error StonkzNotParked(address custody, uint256 bal);
    error WiringFailed(string what);
    error AddressBookMissing();

    struct Book {
        address stonkz;
        address poolManager;
        address governor;
        address hook;
        address feeLocker;
        address accumulator;
        address settlement;
        address vault;
        address express;
        address ladder;
    }

    function run() external {
        _assertChainAllowed();

        // ─── gas posture for ~100ms Orbit blocks (priority fee buys nothing) ──
        vm.txGasPrice(60_000_000); // 0.06 gwei

        address custody = vm.envAddress("CUSTODY_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address pairToken = vm.envOr("PAIR_TOKEN", address(0));
        address usdg = vm.envOr("USDG_ADDRESS", address(0));

        if (custody == address(0)) revert MissingEnv("CUSTODY_ADDRESS");
        if (treasury == address(0)) revert MissingEnv("TREASURY_ADDRESS");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        string memory bookPath = vm.envOr("ADDRESS_BOOK_PATH", string("../deploys/official/addresses.json"));
        Book memory book = _loadBook(bookPath);

        console2.log("Deploy chainId", block.chainid);
        console2.log("Deployer", deployer);
        console2.log("Custody", custody);
        console2.log("Treasury", treasury);

        vm.startBroadcast(pk);

        // 1) Protocol token — full supply to custody; no pools; no approvals.
        //    Optional CREATE2: set STONKZ_CREATE2_SALT (bytes32 hex) from vanity-mine --mode eoa.
        //    Decision (Phase 1): YES mine 0x4663 for the protocol token; 0x46634663 remains OPEN.
        if (!_hasCode(book.stonkz)) {
            bytes32 tokenSalt = vm.envOr("STONKZ_CREATE2_SALT", bytes32(0));
            if (tokenSalt != bytes32(0)) {
                book.stonkz = address(new StonkzToken{salt: tokenSalt}(custody));
                require(
                    uint16(uint160(book.stonkz) >> 144) == 0x4663,
                    "STONKZ vanity: salt does not yield 0x4663 prefix"
                );
            } else {
                book.stonkz = address(new StonkzToken(custody));
            }
            console2.log("deployed StonkzToken", book.stonkz);
        } else {
            console2.log("skip StonkzToken", book.stonkz);
        }

        // 2) Settlement venue — MockPoolManager until M3.5 real-v4 wiring.
        if (!_hasCode(book.poolManager)) {
            book.poolManager = address(new MockPoolManager());
            console2.log("deployed MockPoolManager", book.poolManager);
        } else {
            console2.log("skip MockPoolManager", book.poolManager);
        }

        // 3) CTO + hook + registry
        if (!_hasCode(book.governor)) {
            book.governor = address(new CTOGovernor());
            console2.log("deployed CTOGovernor", book.governor);
        } else {
            console2.log("skip CTOGovernor", book.governor);
        }

        if (!_hasCode(book.hook)) {
            book.hook = address(
                new StonkzFeeHook(IPoolManager(book.poolManager), treasury, ICTOGovernor(book.governor))
            );
            console2.log("deployed StonkzFeeHook", book.hook);
        } else {
            console2.log("skip StonkzFeeHook", book.hook);
        }

        if (address(CTOGovernor(book.governor).registry()) == address(0)) {
            CTOGovernor(book.governor).setRegistry(StonkzFeeHook(payable(book.hook)));
        }

        // 4) Fee locker + buyback accumulator (stonkzRef = REAL token)
        if (!_hasCode(book.feeLocker)) {
            book.feeLocker = address(new FeeLockerV2(IPoolManager(book.poolManager), StonkzFeeHook(payable(book.hook))));
            console2.log("deployed FeeLockerV2", book.feeLocker);
        } else {
            console2.log("skip FeeLockerV2", book.feeLocker);
        }

        if (!_hasCode(book.accumulator)) {
            book.accumulator = address(new BuybackAccumulator(pairToken, book.stonkz, address(0)));
            console2.log("deployed BuybackAccumulator", book.accumulator);
        } else {
            console2.log("skip BuybackAccumulator", book.accumulator);
        }

        // 5) Ladder settlement + stamps
        if (!_hasCode(book.settlement)) {
            book.settlement =
                address(new LadderSettlement(IPoolManager(book.poolManager), StonkzFeeHook(payable(book.hook)), pairToken));
            console2.log("deployed LadderSettlement", book.settlement);
        } else {
            console2.log("skip LadderSettlement", book.settlement);
        }
        LadderSettlement(book.settlement).setStonkzRef(book.stonkz);
        LadderSettlement(book.settlement).setFeeLocker(FeeLockerV2(book.feeLocker));

        // 6) Vault
        if (!_hasCode(book.vault)) {
            book.vault = address(
                new StonkzVault(VaultConstants.LAUNCH_RATE_SECONDS_PER_BPS, 1, 10_000)
            );
            console2.log("deployed StonkzVault", book.vault);
        } else {
            console2.log("skip StonkzVault", book.vault);
        }

        // 7) Express factory (DeployControls birth; stonkzRef = REAL token)
        if (!_hasCode(book.express)) {
            book.express = address(
                new StonkzExpressFactory(
                    IPoolManager(book.poolManager),
                    FeeLockerV2(book.feeLocker),
                    StonkzFeeHook(payable(book.hook)),
                    BuybackAccumulator(payable(book.accumulator)),
                    CTOGovernor(book.governor),
                    pairToken,
                    book.stonkz
                )
            );
            console2.log("deployed StonkzExpressFactory", book.express);
        } else {
            console2.log("skip StonkzExpressFactory", book.express);
        }

        // 8) Ladder factory + vaultRef + optional USDG ref seed
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
        // ETH ref is birth-default on DeployControls; assert + leave. Optional runbook re-check.
        if (pairToken != address(0) && pairToken != usdg) {
            // Express already seeds its pairToken in ctor; Ladder needs explicit seed for non-ETH pairs used at file.
            StonkzLadderFactory(book.ladder).setStonkzRefPrice(pairToken, REF_USDG);
        }

        vm.stopBroadcast();

        // ─── post-deploy assertions (read-only; no key) ───────────────────────
        _assertWiring(book, deployer, custody, pairToken, usdg);
        _writeBook(bookPath, book, deployer, custody, treasury, pairToken, usdg);

        console2.log("=== DEPLOY COMPLETE ===");
        console2.log("StonkzToken", book.stonkz);
        console2.log("ExpressFactory", book.express);
        console2.log("LadderFactory", book.ladder);
        console2.log("address book", bookPath);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // chain gate
    // ═══════════════════════════════════════════════════════════════════════

    function _assertChainAllowed() internal view {
        uint256 id = block.chainid;
        if (id == CHAIN_ROBINHOOD) return;
        bool fork = vm.envOr("FORK", false);
        if (id == CHAIN_ANVIL && fork) return;
        revert WrongChain(id);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // idempotency helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _hasCode(address a) internal view returns (bool) {
        return a != address(0) && a.code.length > 0;
    }

    function _loadBook(string memory path) internal view returns (Book memory b) {
        if (!vm.exists(path)) {
            // First run: empty book (placeholder may exist with zero addresses).
            return b;
        }
        string memory raw = vm.readFile(path);
        // Tolerate placeholder zeros / missing keys via try-style reads.
        b.stonkz = _readAddr(raw, ".contracts.StonkzToken");
        b.poolManager = _readAddr(raw, ".contracts.MockPoolManager");
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
        // stdJson reverts on missing key — catch via empty/zero placeholder file always having keys.
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
        vm.serializeAddress(contracts, "StonkzToken", book.stonkz);
        vm.serializeAddress(contracts, "MockPoolManager", book.poolManager);
        vm.serializeAddress(contracts, "CTOGovernor", book.governor);
        vm.serializeAddress(contracts, "StonkzFeeHook", book.hook);
        vm.serializeAddress(contracts, "FeeLockerV2", book.feeLocker);
        vm.serializeAddress(contracts, "BuybackAccumulator", book.accumulator);
        vm.serializeAddress(contracts, "LadderSettlement", book.settlement);
        vm.serializeAddress(contracts, "StonkzVault", book.vault);
        vm.serializeAddress(contracts, "StonkzExpressFactory", book.express);
        string memory contractsJson =
            vm.serializeAddress(contracts, "StonkzLadderFactory", book.ladder);

        string memory config = "config";
        vm.serializeAddress(config, "custody", custody);
        vm.serializeAddress(config, "treasury", treasury);
        vm.serializeAddress(config, "pairToken", pairToken);
        vm.serializeAddress(config, "usdg", usdg);
        vm.serializeString(config, "refPriceEthWad", "250000000000");
        vm.serializeString(config, "refPriceUsdgWad", "1000000000000000");
        string memory configJson = vm.serializeString(
            config,
            "poolManagerNote",
            "MockPoolManager - M3.5 real Uniswap v4 PoolManager wiring NOT STARTED"
        );

        string memory wiring = "wiring";
        vm.serializeBool(wiring, "vaultRef", true);
        vm.serializeBool(wiring, "settlementStonkzRef", true);
        vm.serializeBool(wiring, "settlementFeeLocker", true);
        vm.serializeBool(wiring, "govRegistry", true);
        vm.serializeBool(wiring, "softLaunchExpress", true);
        vm.serializeBool(wiring, "softLaunchLadder", true);
        string memory wiringJson = vm.serializeBool(wiring, "stonkzSupplyParked", true);

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

    // ═══════════════════════════════════════════════════════════════════════
    // wiring assertions
    // ═══════════════════════════════════════════════════════════════════════

    function _assertWiring(Book memory book, address deployer, address custody, address pairToken, address usdg)
        internal
        view
    {
        // Soft-launch: closed + deployer-only on BOTH DeployControls instances.
        _assertSoftLaunchGate(DeployControls(book.express), deployer);
        _assertSoftLaunchGate(DeployControls(book.ladder), deployer);

        StonkzExpressFactory express = StonkzExpressFactory(book.express);
        if (express.stonkzRef() != book.stonkz) revert WiringFailed("express.stonkzRef");
        if (address(express.hook()) != book.hook) revert WiringFailed("express.hook");

        StonkzLadderFactory ladder = StonkzLadderFactory(book.ladder);
        if (ladder.vaultRef() != book.vault) revert WiringFailed("ladder.vaultRef");

        LadderSettlement settlement = LadderSettlement(book.settlement);
        if (settlement.stonkzRef() != book.stonkz) revert WiringFailed("settlement.stonkzRef");
        if (address(settlement.feeLocker()) != book.feeLocker) revert WiringFailed("settlement.feeLocker");

        if (address(CTOGovernor(book.governor).registry()) != book.hook) revert WiringFailed("gov.registry");

        // Ref prices: ETH 2.5e11 on both factories; USDG 1e15 when configured.
        uint256 ethExpress = express.stonkzRefPriceWad(address(0));
        uint256 ethLadder = ladder.stonkzRefPriceWad(address(0));
        if (ethExpress != REF_ETH) revert RefPriceMismatch(address(0), ethExpress, REF_ETH);
        if (ethLadder != REF_ETH) revert RefPriceMismatch(address(0), ethLadder, REF_ETH);

        if (usdg != address(0)) {
            uint256 u = ladder.stonkzRefPriceWad(usdg);
            if (u != REF_USDG) revert RefPriceMismatch(usdg, u, REF_USDG);
        }
        if (pairToken != address(0)) {
            uint256 p = express.stonkzRefPriceWad(pairToken);
            if (p != REF_USDG) revert RefPriceMismatch(pairToken, p, REF_USDG);
        }

        // Supply parked at custody; zero circulating intent (no pools in this script).
        uint256 bal = StonkzToken(book.stonkz).balanceOf(custody);
        if (bal != StonkzToken(book.stonkz).TOTAL_SUPPLY()) revert StonkzNotParked(custody, bal);

        BuybackAccumulator acc = BuybackAccumulator(payable(book.accumulator));
        if (acc.stonkz4663() != book.stonkz) revert WiringFailed("accumulator.stonkz");
    }
}
