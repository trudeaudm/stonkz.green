// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager as ICanonPM} from "@v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@v4-core/src/libraries/Hooks.sol";

import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {V4Adapter} from "../src/v4/V4Adapter.sol";
import {HookVanity} from "../src/HookVanity.sol";
import {StonkzToken} from "../src/StonkzToken.sol";
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
import {StonkzLadderAuction} from "../src/ladder/StonkzLadderAuction.sol";
import {LadderConstants} from "../src/ladder/LadderConstants.sol";
import {LadderTypes} from "../src/ladder/LadderTypes.sol";

import {VanityHelpers} from "./VanityHelpers.sol";
import {Vanity} from "../src/Vanity.sol";

/// @dev Minimal ERC20 for settle ask inventory + vault holdback (Phase 4 pattern).
contract ForkProofERC20 {
    string public name = "ForkProof";
    string public symbol = "FP";
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

/// @title DeployScriptForkProof — short gate: script-parity stack on RH fork + graduating Ladder
/// @notice Mirrors Deploy.s.sol wiring (RH PM + V4Adapter + fee hook + factories). No MockPoolManager.
///         Hook CREATE2: flag-valid 0x088. Official Deploy.s.sol still requires HOOK_CREATE2_SALT
///         with full 0x4663+0x088 from hook-vanity-mine.mjs.
/// @dev Run: forge test --match-contract DeployScriptForkProof -vvv --gas-limit 20000000000
contract DeployScriptForkProof is Test {
    address internal constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant UNIVERSAL_ROUTER = 0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 internal constant PHASE4_FILE_GAS_REF = 29_274_312;
    uint256 internal constant ORBIT_BLOCK_GAS_LIMIT = 32_000_000;
    uint256 internal constant SUPPLY = 1_000_000 ether;

    address internal constant PAIR = address(0);
    address internal custody = address(0xC05D0D);
    address internal treasury = address(0x7A5E);
    address internal creator = address(0xCEEE);
    address internal bidder = address(0xB1D);

    V4Adapter internal adapter;
    IPoolManager internal pm;
    StonkzToken internal stonkz;
    CTOGovernor internal gov;
    StonkzFeeHook internal hook;
    FeeLockerV2 internal locker;
    BuybackAccumulator internal acc;
    LadderSettlement internal settlement;
    StonkzVault internal vault;
    StonkzExpressFactory internal express;
    StonkzLadderFactory internal ladder;

    uint256 internal fileGasUsed;
    uint256 internal fileSaltNonce;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        vm.createSelectFork(rpc);
        require(block.chainid == 4663, "fork chainId != 4663");
        require(RH_POOL_MANAGER.code.length > 0, "RH PM");
        require(UNIVERSAL_ROUTER.code.length > 0, "UR");
        require(PERMIT2.code.length > 0, "Permit2");

        stonkz = new StonkzToken(custody);
        adapter = new V4Adapter(ICanonPM(RH_POOL_MANAGER));
        pm = IPoolManager(address(adapter));
        gov = new CTOGovernor();
        hook = _deployFlagHook();
        hook.bindCanonManager(ICanonPM(RH_POOL_MANAGER));
        hook.validateHookAddress(address(hook));
        gov.setRegistry(hook);
        locker = new FeeLockerV2(pm, hook);
        acc = new BuybackAccumulator(PAIR, address(stonkz), address(0));
        settlement = new LadderSettlement(pm, hook, PAIR);
        settlement.setStonkzRef(address(stonkz));
        settlement.setFeeLocker(locker);
        vault = new StonkzVault(VaultConstants.LAUNCH_RATE_SECONDS_PER_BPS, 1, 10_000);
        express = new StonkzExpressFactory(pm, locker, hook, acc, gov, PAIR, address(stonkz));
        ladder = new StonkzLadderFactory();
        ladder.setVaultRef(address(vault));

        express.assertSoftLaunchGate(address(this));
        ladder.assertSoftLaunchGate(address(this));

        console2.log("SCRIPT-PARITY adapter", address(adapter));
        console2.log("SCRIPT-PARITY hook", address(hook));
        console2.log("SCRIPT-PARITY settlement", address(settlement));
        console2.log("SCRIPT-PARITY ladder", address(ladder));
    }

    function test_fork_scriptParity_graduatingLadder_fileGas() public {
        assertEq(address(adapter.manager()), RH_POOL_MANAGER);
        assertEq(address(hook.canonManager()), RH_POOL_MANAGER);
        assertEq(HookVanity.flagsOf(address(hook)), HookVanity.HOOK_FLAGS);
        assertEq(ladder.vaultRef(), address(vault));
        assertEq(settlement.stonkzRef(), address(stonkz));
        assertEq(express.stonkzRefPriceWad(address(0)), 2.5e11);
        assertEq(ladder.stonkzRefPriceWad(address(0)), 2.5e11);

        StonkzLadderAuction.Params memory p = _ladderParams();
        p.holdbackBps = 1000;
        p.holdbackDelivery = LadderConstants.HoldbackDelivery.Vault;
        p.floorMcap = 10_000e18;
        p.tier = LadderTypes.Tier.Daily;
        p.walletCapBps = 1000;

        // LadderSettlement is single-use — fresh instance from script-parity wiring (same as Deploy).
        LadderSettlement settleInst = new LadderSettlement(pm, hook, PAIR);
        settleInst.setStonkzRef(address(stonkz));
        settleInst.setFeeLocker(locker);

        (bytes32 userSalt,) = VanityHelpers.mineLadder(ladder, address(this), p);
        uint256 g0 = gasleft();
        StonkzLadderAuction a = ladder.file(p, userSalt);
        fileGasUsed = g0 - gasleft();
        console2.log("script-parity file() gas (excl. vanity mine)", fileGasUsed);
        console2.log("Phase4 file() ref", PHASE4_FILE_GAS_REF);
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
        console2.log("raised", a.raised());
        console2.log("threshold", a.threshold());
        console2.log("graduated", a.graduated());
        assertTrue(a.graduated(), "must graduate");

        // Settlement consumes an ERC20 ask inventory (Phase 4 fork pattern).
        ForkProofERC20 tok = new ForkProofERC20();
        uint256 unsold = a.auctionSupply() > a.soldTokens() ? a.auctionSupply() - a.soldTokens() : 0;
        uint256 side = (unsold * a.sidePoolBps()) / 10_000;
        uint256 mainAsk = unsold - side;
        uint256 hb = a.holdbackAmount();
        tok.mint(address(settleInst), hb + mainAsk + side);

        a.settle(address(tok));
        assertTrue(settleInst.askLiquidity() > 0 || settleInst.cashLiquidity() > 0, "settle LP");
        assertEq(vault.balanceOf(address(tok), creator), hb, "vault deposit");

        assertLt(fileGasUsed, ORBIT_BLOCK_GAS_LIMIT, "file fits Orbit");
        int256 delta = int256(fileGasUsed) - int256(PHASE4_FILE_GAS_REF);
        console2.log("file() gas delta vs Phase4", delta);
        uint256 absDelta = delta < 0 ? uint256(-delta) : uint256(delta);
        assertLt(absDelta, PHASE4_FILE_GAS_REF / 50, "file gas divergence >2% vs Phase4");

        console2.log("=== DEPLOY SCRIPT FORK RE-PROOF OK ===");
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
        p.stonkzRefPriceWad = 2.5e11;
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
