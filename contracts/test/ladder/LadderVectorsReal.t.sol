// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@v4-core/src/libraries/Hooks.sol";
import {IPoolManager as ICanonPM} from "@v4-core/src/interfaces/IPoolManager.sol";
import {Deployers} from "@v4-core/test/utils/Deployers.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {LadderVectorLoader} from "./LadderVectorLoader.sol";
import {LadderAsserts} from "./LadderAsserts.sol";
import {LadderTypes} from "../../src/ladder/LadderTypes.sol";
import {LadderConstants} from "../../src/ladder/LadderConstants.sol";
import {LadderTolerance} from "./LadderTolerance.sol";
import {StonkzLadderAuction} from "../../src/ladder/StonkzLadderAuction.sol";
import {LadderSettlement} from "../../src/ladder/LadderSettlement.sol";
import {IPoolManager} from "../../src/v4/IPoolManager.sol";
import {V4Adapter} from "../../src/v4/V4Adapter.sol";
import {StonkzFeeHook} from "../../src/StonkzFeeHook.sol";
import {HookVanity} from "../../src/HookVanity.sol";
import {FeeLockerV2} from "../../src/FeeLockerV2.sol";
import {CTOGovernor} from "../../src/CTOGovernor.sol";
import {ICTOGovernor} from "../../src/interfaces/IStonkzGovernance.sol";
import {MockVault} from "./MockVault.sol";

/// @title LadderVectorsReal — V4-CANON Phase 3: A1–A5 × 10 on Real backend + settle canary
contract LadderVectorsReal is Test, Deployers, LadderVectorLoader, LadderAsserts {
    using stdJson for string;

    StonkzLadderAuction internal auction;
    LadderSettlement internal settlement;
    StonkzFeeHook internal hook;
    FeeLockerV2 internal locker;
    V4Adapter internal adapter;
    IPoolManager internal pm;
    MockVault internal mockVault;
    MockLaunchTokenReal internal tok;

    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCE0);
    MockLaunchTokenReal internal stonkzToken;

    function setUp() public {
        deployFreshManagerAndRouters();
        mockVault = new MockVault();
        adapter = new V4Adapter(manager);
        pm = IPoolManager(address(adapter));
        adapter.setAuthorized(address(this), true);
        CTOGovernor gov = new CTOGovernor();
        hook = _deployFlagHook(gov);
        hook.bindCanonManager(manager);
        gov.setRegistry(hook);
        locker = new FeeLockerV2(pm, hook);
        adapter.setAuthorized(address(locker), true);
        settlement = new LadderSettlement(pm, hook, address(0));
        adapter.setAuthorized(address(settlement), true);
        settlement.setFeeLocker(locker);
        // Real PM needs a contract at sideTokenRef (side pool currency) — not bare 0x4663.
        stonkzToken = new MockLaunchTokenReal();
        settlement.setSideTokenRef(address(stonkzToken));
        tok = new MockLaunchTokenReal();
    }

    function _deployFlagHook(CTOGovernor gov) internal returns (StonkzFeeHook h) {
        bytes memory creation = abi.encodePacked(
            type(StonkzFeeHook).creationCode,
            abi.encode(pm, TREASURY, ICTOGovernor(address(gov)), address(this))
        );
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
        require(found, "flag salt");
        h = new StonkzFeeHook{salt: salt}(pm, TREASURY, ICTOGovernor(address(gov)), address(this));
        require(address(h) == predicted, "create2");
    }

    function _duration(LadderTypes.Tier t) internal pure returns (uint256) {
        if (t == LadderTypes.Tier.God) return LadderConstants.GOD_DURATION;
        if (t == LadderTypes.Tier.H4) return LadderConstants.H4_DURATION;
        if (t == LadderTypes.Tier.Daily) return LadderConstants.DAILY_DURATION;
        return LadderConstants.ROAD_DURATION;
    }

    function _params(LadderTypes.Inputs memory inn, address vault)
        internal
        view
        returns (StonkzLadderAuction.Params memory p)
    {
        p.supply = inn.supply;
        p.auctionSupply = inn.auctionSupply;
        p.floorMcap = inn.floorMcap;
        p.duration = _duration(inn.tier);
        p.lpShareWad = inn.lpShare;
        p.lpHealthTargetWad = inn.lpHealthTarget;
        p.carveBps = inn.protocolCarveBps;
        p.cashHoldbackBps = inn.cashHoldbackBps;
        p.holdbackBps = inn.holdbackBps;
        p.holdbackDelivery = inn.holdbackBps > 0
            ? LadderConstants.HoldbackDelivery.Vault
            : LadderConstants.HoldbackDelivery.None;
        p.tier = inn.tier;
        p.createSidePool = true;
        p.sidePoolBps = inn.sidePoolBps;
        p.refPriceWad = 2.5e11;
        p.walletCapBps = inn.walletCapBps;
        p.sizeBonusBps = inn.sizeBonusBps;
        p.maxUniqueActives = 300;
        p.pairToken = address(0);
        p.creator = CREATOR;
        p.treasury = TREASURY;
        p.vaultRef = vault;
        p.settlement = address(settlement);
    }

    function _replay(string memory file) internal {
        string memory json = _loadRaw(file);
        LadderTypes.Inputs memory inn = loadInputs(json);
        LadderTypes.Bid[] memory bids = loadBids(json);
        LadderTypes.Outputs memory exp = loadOutputs(json);
        LadderTypes.PathRow[] memory path = loadPath(json);

        address vault = inn.holdbackBps > 0 ? address(mockVault) : address(0);
        auction = new StonkzLadderAuction(_params(inn, vault));
        auction.start();
        for (uint256 i; i < bids.length; i++) {
            address w = bids[i].wallet;
            vm.deal(w, bids[i].size + 1 ether);
            vm.prank(w);
            auction.placeBid{value: bids[i].size}(bids[i].size, bids[i].maxPrice);
        }
        auction.clearAllForTest();

        (uint256 toLP, uint256 toTreasury, uint256 toCreator) = auction.raiseSplit();
        LadderTypes.RaiseSplit memory split =
            LadderTypes.RaiseSplit({toLP: toLP, toTreasury: toTreasury, toCreator: toCreator});

        LadderTypes.Fill[] memory gotFills = new LadderTypes.Fill[](exp.fills.length);
        for (uint256 i; i < exp.fills.length; i++) {
            address w = exp.fills[i].wallet;
            (uint256 c, uint256 s, uint256 t, uint256 r) = auction.fillOf(w);
            gotFills[i] = LadderTypes.Fill({wallet: w, committed: c, spent: s, tokens: t, refund: r});
        }

        LadderTypes.PathRow[] memory gotPath = new LadderTypes.PathRow[](path.length);
        for (uint16 per = 1; per <= LadderConstants.DESIGN_N; per++) {
            gotPath[per - 1] = LadderTypes.PathRow({
                period: per,
                price: auction.pathPrice(per),
                offered: auction.pathOffered(per),
                sold: auction.pathSold(per),
                phase: bytes32(0)
            });
        }

        assertA1_raiseSplit(split, auction.raised(), exp.raiseSplit);
        assertA2_fillConservation(gotFills, exp.fills, auction.raised(), auction.committedTotal());
        assertEq(auction.graduated(), exp.graduated, "A3 graduated");
        assertA4_lpHealth(auction.graduated(), auction.lpHealth(), exp.lpHealthFloor);
        if (exp.graduated) {
            assertApproxEqAbs(auction.lpHealth(), exp.lpHealth, LadderTolerance.fracTol(exp.lpHealth), "lpH vs vec");
        }
        assertA5_rungGrid(gotPath, inn.floorMcap, inn.supply, inn.rungIntervalUsd);
        assertApproxEqAbs(auction.price(), exp.clearingPrice, 1, "clearP");
        assertApproxEqAbs(auction.lpHealth(), exp.lpHealth, LadderTolerance.fracTol(exp.lpHealth), "lpH");
    }

    function test_real_A1A5_01() public {
        _replay("01-thin-book-fails.json");
    }

    function test_real_A1A5_02() public {
        _replay("02-god-2p5k-at-bar.json");
    }

    function test_real_A1A5_03() public {
        _replay("03-god-5k-oversub.json");
    }

    function test_real_A1A5_04() public {
        _replay("04-4h-5k-at-bar.json");
    }

    function test_real_A1A5_05() public {
        _replay("05-daily-10k-at-bar.json");
    }

    function test_real_A1A5_06() public {
        _replay("06-daily-20k-heavy.json");
    }

    function test_real_A1A5_07() public {
        _replay("07-road-40k-at-bar.json");
    }

    function test_real_A1A5_08() public {
        _replay("08-locked-holdback-60.json");
    }

    function test_real_A1A5_10() public {
        _replay("10-wallet-cap-binding.json");
    }

    /// @notice Vector 09: A1–A5 + settle through Real V4Adapter (cash+ask geometry).
    function test_real_A1A5_09_settleOnAdapter() public {
        string memory json = _loadRaw("09-vault-holdback-cashhb.json");
        LadderTypes.Inputs memory inn = loadInputs(json);
        LadderTypes.Bid[] memory bids = loadBids(json);
        LadderTypes.Outputs memory exp = loadOutputs(json);

        auction = new StonkzLadderAuction(_params(inn, address(mockVault)));
        auction.start();
        for (uint256 i; i < bids.length; i++) {
            address w = bids[i].wallet;
            vm.deal(w, bids[i].size + 1 ether);
            vm.prank(w);
            auction.placeBid{value: bids[i].size}(bids[i].size, bids[i].maxPrice);
        }
        auction.clearAllForTest();
        assertTrue(auction.graduated(), "09 graduated");
        assertApproxEqAbs(auction.lpHealth(), exp.lpHealth, LadderTolerance.fracTol(exp.lpHealth), "lpH");

        uint256 unsold = inn.auctionSupply - auction.soldTokens();
        uint256 side = (unsold * inn.sidePoolBps) / 10_000;
        uint256 mainAsk = unsold - side;
        uint256 vaultAmt = (inn.supply * inn.holdbackBps) / 10_000;
        tok.mint(address(settlement), vaultAmt + mainAsk + side);
        // ETH for cash leg already arrives via auction.settle → settlement.settle{value: raised}.

        auction.settle(address(tok));

        assertTrue(hook.registered(address(tok)), "hook registered");
        assertTrue(settlement.askTickLower() < settlement.askTickUpper(), "ask range");
        assertTrue(settlement.cashTickLower() < settlement.cashTickUpper(), "cash range");
        assertGt(settlement.cashLiquidity(), 0, "cash lp");
        assertGt(settlement.askLiquidity(), 0, "ask lp");
        // pairIs0 (native < token): cash above print in tick space, ask at/below print.
        assertGt(settlement.cashTickLower(), settlement.askTickUpper(), "pairIs0 orientation");
    }

    function test_real_A1A5_09() public {
        _replay("09-vault-holdback-cashhb.json");
    }
}

contract MockLaunchTokenReal {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
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
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}
