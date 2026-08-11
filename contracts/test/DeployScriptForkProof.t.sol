// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager as ICanonPM} from "@v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@v4-core/src/libraries/Hooks.sol";

import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {V4Adapter} from "../src/v4/V4Adapter.sol";
import {Currency} from "../src/v4/types/Currency.sol";
import {HookVanity} from "../src/HookVanity.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {FeeLockerV2} from "../src/FeeLockerV2.sol";
import {BuybackAccumulator, IBuyExecutor} from "../src/BuybackAccumulator.sol";
import {PoolKey} from "../src/v4/types/PoolKey.sol";
import {LadderSettlement} from "../src/ladder/LadderSettlement.sol";
import {StonkzVault} from "../src/vault/StonkzVault.sol";
import {VaultConstants} from "../src/vault/VaultConstants.sol";
import {StonkzExpressFactory} from "../src/StonkzExpressFactory.sol";
import {StonkzLadderFactory} from "../src/ladder/StonkzLadderFactory.sol";
import {StonkzLadderAuction} from "../src/ladder/StonkzLadderAuction.sol";
import {LadderConstants} from "../src/ladder/LadderConstants.sol";
import {LadderTypes} from "../src/ladder/LadderTypes.sol";
import {VanityHelpers} from "./VanityHelpers.sol";
import {Vanity} from "../src/Vanity.sol";

/// @dev Stand-in dead ERC-20 (STONKZ_REF_ADDRESS) + settle ask inventory helper.
contract StandInERC20 {
    string public name = "StandInDead";
    string public symbol = "DEAD";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev 1:1 pair→side executor for accumulator crank on fork.
contract ScriptMockBuyExecutor is IBuyExecutor {
    StandInERC20 public immutable side;
    uint256 public outWad = 1e18;

    constructor(StandInERC20 side_) {
        side = side_;
    }

    function buyExactIn(uint256 amountIn, uint256 minAmountOut) external payable returns (uint256 amountOut) {
        amountOut = (amountIn * outWad) / 1e18;
        require(amountOut >= minAmountOut, "slip");
        side.transfer(msg.sender, amountOut);
    }

    receive() external payable {}
}

/// @title DeployScriptForkProof — script-parity on RH fork after GENESIS VIA PLATFORM
/// @notice No StonkzToken. sideTokenRef = stand-in ERC-20. Graduating Ladder settle; side pool
///         pairs against stand-in (dormant). Run: forge test --match-contract DeployScriptForkProof -vvv
contract DeployScriptForkProof is Test {
    address internal constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant UNIVERSAL_ROUTER = 0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 internal constant PHASE4_FILE_GAS_REF = 29_274_312;
    uint256 internal constant PRIOR_SCRIPT_FILE_GAS_REF = 29_305_993; // pre-stand-in re-proof
    uint256 internal constant ORBIT_BLOCK_GAS_LIMIT = 32_000_000;
    uint256 internal constant SUPPLY = 1_000_000 ether;

    address internal constant PAIR = address(0);
    address internal custody = address(0xC05D0D);
    address internal treasury = address(0x7A5E);
    address internal creator = address(0xCEEE);

    V4Adapter internal adapter;
    IPoolManager internal pm;
    StandInERC20 internal standIn;
    CTOGovernor internal gov;
    StonkzFeeHook internal hook;
    FeeLockerV2 internal locker;
    BuybackAccumulator internal acc;
    LadderSettlement internal settlement;
    StonkzVault internal vault;
    StonkzExpressFactory internal express;
    StonkzLadderFactory internal ladder;

    uint256 internal fileGasUsed;
    uint256 internal standInSupplyBefore;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        vm.createSelectFork(rpc);
        require(block.chainid == 4663, "fork chainId != 4663");
        require(RH_POOL_MANAGER.code.length > 0, "RH PM");
        require(UNIVERSAL_ROUTER.code.length > 0, "UR");
        require(PERMIT2.code.length > 0, "Permit2");

        // Real ERC-20 with code on the fork (script would take this as STONKZ_REF_ADDRESS).
        standIn = new StandInERC20();
        standIn.mint(address(0xDEAD), 1); // tiny inert supply — not protocol STONKZ
        standInSupplyBefore = standIn.totalSupply();
        require(address(standIn).code.length > 0, "stand-in code");
        require(standIn.decimals() == 18, "stand-in decimals");

        adapter = new V4Adapter(ICanonPM(RH_POOL_MANAGER));
        pm = IPoolManager(address(adapter));
        gov = new CTOGovernor();
        hook = _deployFlagHook();
        hook.bindCanonManager(ICanonPM(RH_POOL_MANAGER));
        hook.validateHookAddress(address(hook));
        gov.setRegistry(hook);
        locker = new FeeLockerV2(pm, hook);
        acc = new BuybackAccumulator(PAIR, address(standIn), address(0));
        settlement = new LadderSettlement(pm, hook, PAIR);
        settlement.setSideTokenRef(address(standIn));
        settlement.setFeeLocker(locker);
        vault = new StonkzVault(VaultConstants.LAUNCH_RATE_SECONDS_PER_BPS, 1, 10_000);
        express = new StonkzExpressFactory(pm, locker, hook, acc, gov, PAIR, address(standIn));
        ladder = new StonkzLadderFactory();
        ladder.setVaultRef(address(vault));
        ladder.setSideTokenRef(address(standIn));

        express.transferOwnership(custody);
        ladder.transferOwnership(custody);
        hook.transferOwnership(custody);
        settlement.transferOwnership(custody);
        vault.transferOwnership(custody);

        express.assertSoftLaunchGate(address(this));
        ladder.assertSoftLaunchGate(address(this));

        console2.log("SCRIPT-PARITY stand-in", address(standIn));
        console2.log("SCRIPT-PARITY adapter", address(adapter));
        console2.log("SCRIPT-PARITY hook", address(hook));
    }

    function test_fork_scriptParity_graduatingLadder_standInSidePool() public {
        assertEq(express.sideTokenRef(), address(standIn));
        assertEq(settlement.sideTokenRef(), address(standIn));
        assertEq(acc.sideTokenRef(), address(standIn));
        assertEq(express.owner(), custody);
        assertEq(standIn.balanceOf(custody), 0, "custody not a mint target");

        StonkzLadderAuction.Params memory p = _ladderParams();
        p.holdbackBps = 1000;
        p.holdbackDelivery = LadderConstants.HoldbackDelivery.Vault;
        p.floorMcap = 10_000e18;
        p.tier = LadderTypes.Tier.Daily;
        p.walletCapBps = 1000;

        LadderSettlement settleInst = new LadderSettlement(pm, hook, PAIR);
        settleInst.setSideTokenRef(address(standIn));
        settleInst.setFeeLocker(locker);

        (bytes32 userSalt,) = VanityHelpers.mineLadder(ladder, address(this), p);
        uint256 g0 = gasleft();
        StonkzLadderAuction a = ladder.file(p, userSalt);
        fileGasUsed = g0 - gasleft();
        console2.log("script-parity file() gas (excl. vanity mine)", fileGasUsed);
        console2.log("Phase4 file() ref", PHASE4_FILE_GAS_REF);
        console2.log("prior script-parity file() ref", PRIOR_SCRIPT_FILE_GAS_REF);
        assertTrue(Vanity.matches(address(a)), "ladder vanity");

        vm.prank(address(ladder));
        a.setSettlement(settleInst);
        a.start();

        uint256 need = a.threshold();
        uint256 nBid = 12;
        uint256 bidSize = need / 8 + 50 ether;
        if (bidSize < 5 ether) bidSize = 5 ether;
        for (uint256 i; i < nBid; ++i) {
            address w = address(uint160(0xB100 + i));
            vm.deal(w, bidSize * 2);
            vm.prank(w);
            a.placeBid{value: bidSize}(bidSize, type(uint256).max);
        }
        a.clearNextForTest();
        a.clearNextForTest();
        vm.warp(a.startTime() + a.duration() + 1);
        a.clearAllForTest();
        assertTrue(a.done());
        assertTrue(a.graduated(), "must graduate");

        StandInERC20 launchTok = new StandInERC20();
        uint256 unsold = a.auctionSupply() > a.soldTokens() ? a.auctionSupply() - a.soldTokens() : 0;
        uint256 side = (unsold * a.sidePoolBps()) / 10_000;
        uint256 mainAsk = unsold - side;
        uint256 hb = a.holdbackAmount();
        launchTok.mint(address(settleInst), hb + mainAsk + side);

        a.settle(address(launchTok));
        assertTrue(settleInst.askLiquidity() > 0 || settleInst.cashLiquidity() > 0, "settle LP");
        assertEq(vault.balanceOf(address(launchTok), creator), hb, "vault deposit");

        // Side pool pairs against stand-in and is dormant (stand-in supply unchanged; no STONKZ).
        (Currency sideC0, Currency sideC1,,,) = settleInst.sidePoolKey();
        address c0 = Currency.unwrap(sideC0);
        address c1 = Currency.unwrap(sideC1);
        assertTrue(c0 == address(standIn) || c1 == address(standIn), "side pairs vs stand-in");
        assertTrue(c0 == address(launchTok) || c1 == address(launchTok), "side pairs vs launch tok");
        assertEq(standIn.totalSupply(), standInSupplyBefore, "stand-in supply dormant");
        assertEq(standIn.balanceOf(custody), 0, "stand-in not at custody");
        console2.log("side pool vs stand-in: OK (dormant)");

        assertLt(fileGasUsed, ORBIT_BLOCK_GAS_LIMIT, "file fits Orbit");
        int256 delta = int256(fileGasUsed) - int256(PHASE4_FILE_GAS_REF);
        console2.log("file() gas delta vs Phase4", delta);
        uint256 absDelta = delta < 0 ? uint256(-delta) : uint256(delta);
        assertLt(absDelta, PHASE4_FILE_GAS_REF / 50, "file gas divergence >2% vs Phase4");

        _accumulatorFundCrankBurn();

        console2.log("=== DEPLOY SCRIPT FORK RE-PROOF (STAND-IN) OK ===");
    }

    /// @dev Accumulator v2 fund→crank→burn (mock executor; real PM for spot) — matches refit ForkCanon.
    function _accumulatorFundCrankBurn() internal {
        console2.log("--- Accumulator fund -> crank -> burn ---");
        address dead = address(0x000000000000000000000000000000000000dEaD);
        StandInERC20 side = new StandInERC20();
        ScriptMockBuyExecutor exec = new ScriptMockBuyExecutor(side);
        side.mint(address(exec), 1_000_000 ether);

        BuybackAccumulator a2 = new BuybackAccumulator(PAIR, address(side), address(0));
        a2.setPoolManager(address(adapter));
        a2.setExecutor(address(exec));
        a2.setKeeper(address(this));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(PAIR),
            currency1: Currency.wrap(address(side)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        require(PAIR < address(side), "curr order");
        adapter.initialize(key, uint160(1) << 96);
        a2.setBuyPoolKey(key);

        vm.deal(address(this), address(this).balance + 100 ether);
        a2.fundETH{value: 100 ether}();
        (uint256 inAmt, uint256 outAmt, uint256 burned) = a2.crank(200);
        assertEq(inAmt, 2 ether);
        assertEq(outAmt, 2 ether);
        assertEq(burned, 2 ether);
        assertEq(side.balanceOf(dead), 2 ether);
        console2.log("accumulator fund->crank->burn: OK");
    }

    function _deployFlagHook() internal returns (StonkzFeeHook h) {
        bytes memory creation =
            abi.encodePacked(type(StonkzFeeHook).creationCode, abi.encode(pm, treasury, ICTOGovernor(address(gov))));
        bytes32 initCodeHash = keccak256(creation);
        bytes32 salt;
        address predicted;
        uint256 freemem;
        assembly {
            freemem := mload(0x40)
        }
        bool found;
        for (uint256 i; i < 1_000_000; ++i) {
            assembly {
                mstore(0x40, freemem)
            }
            salt = bytes32(i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash))))
            );
            if ((uint160(predicted) & Hooks.ALL_HOOK_MASK) == HookVanity.HOOK_FLAGS) {
                found = true;
                break;
            }
        }
        require(found, "no flag salt");
        h = new StonkzFeeHook{salt: salt}(pm, treasury, ICTOGovernor(address(gov)));
        require(address(h) == predicted, "flag create2");
    }

    function _ladderParams() internal view returns (StonkzLadderAuction.Params memory p) {
        p.supply = SUPPLY;
        p.auctionSupply = (SUPPLY * 60) / 100;
        p.floorMcap = 40_000e18;
        p.duration = 1 hours;
        p.lpShareWad = 0.95e18;
        p.lpHealthTargetWad = 0.5e18;
        p.carveBps = type(uint16).max;
        p.cashHoldbackBps = 0;
        p.holdbackBps = 0;
        p.holdbackDelivery = LadderConstants.HoldbackDelivery.None;
        p.tier = LadderTypes.Tier.God;
        p.createSidePool = true;
        p.sidePoolBps = 500;
        p.refPriceWad = 2.5e11;
        p.walletCapBps = 100;
        p.sizeBonusBps = 1000;
        p.maxUniqueActives = 0;
        p.pairToken = PAIR;
        p.creator = creator;
        p.treasury = treasury;
        p.vaultRef = address(0);
        p.settlement = address(0);
    }

    receive() external payable {}
}
