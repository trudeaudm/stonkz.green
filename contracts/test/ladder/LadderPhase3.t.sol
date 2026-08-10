// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {stdJson} from "forge-std/StdJson.sol";
import {LadderVectorLoader} from "./LadderVectorLoader.sol";
import {LadderAsserts} from "./LadderAsserts.sol";
import {LadderTypes} from "../../src/ladder/LadderTypes.sol";
import {LadderConstants} from "../../src/ladder/LadderConstants.sol";
import {LadderTolerance} from "./LadderTolerance.sol";
import {StonkzLadderAuction} from "../../src/ladder/StonkzLadderAuction.sol";
import {StonkzLadderFactory} from "../../src/ladder/StonkzLadderFactory.sol";
import {LadderSettlement} from "../../src/ladder/LadderSettlement.sol";
import {IPoolManager} from "../../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../../src/mock/MockPoolManager.sol";
import {StonkzFeeHook} from "../../src/StonkzFeeHook.sol";
import {CTOGovernor} from "../../src/CTOGovernor.sol";
import {ICTOGovernor} from "../../src/interfaces/IStonkzGovernance.sol";
import {PoolKey, PoolIdLibrary} from "../../src/v4/types/PoolKey.sol";
import {MockVault} from "./MockVault.sol";

/// @title LadderPhase3 — gate + settlement; full A1–A5 incl. vector 09 vault+cashHB
contract LadderPhase3 is LadderVectorLoader, LadderAsserts {
    using stdJson for string;
    using PoolIdLibrary for PoolKey;

    StonkzLadderAuction internal auction;
    StonkzLadderFactory internal factory;
    LadderSettlement internal settlement;
    MockPoolManager internal pm;
    StonkzFeeHook internal hook;
    MockLaunchToken internal tok;
    MockVault internal mockVault;

    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCE0);
    address internal constant PAIR = address(0xB111);
    address internal constant STONKZ = address(0x4663);

    function setUp() public {
        mockVault = new MockVault();
        pm = new MockPoolManager();
        CTOGovernor gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)));
        gov.setRegistry(hook);
        settlement = new LadderSettlement(IPoolManager(address(pm)), hook, PAIR);
        settlement.setStonkzRef(STONKZ);
        factory = new StonkzLadderFactory();
        factory.setVaultRef(address(mockVault));
        tok = new MockLaunchToken();
    }

    function _duration(LadderTypes.Tier t) internal pure returns (uint256) {
        if (t == LadderTypes.Tier.God) return LadderConstants.GOD_DURATION;
        if (t == LadderTypes.Tier.H4) return LadderConstants.H4_DURATION;
        if (t == LadderTypes.Tier.Daily) return LadderConstants.DAILY_DURATION;
        return LadderConstants.ROAD_DURATION;
    }

    function _params(LadderTypes.Inputs memory inn, address vault)
        internal
        pure
        returns (StonkzLadderAuction.Params memory p)
    {
        p = StonkzLadderAuction.Params({
            supply: inn.supply,
            auctionSupply: inn.auctionSupply,
            floorMcap: inn.floorMcap,
            duration: _duration(inn.tier),
            lpShareWad: inn.lpShare,
            lpHealthTargetWad: inn.lpHealthTarget,
            carveBps: inn.protocolCarveBps,
            cashHoldbackBps: inn.cashHoldbackBps,
            holdbackBps: inn.holdbackBps,
            holdbackDelivery: inn.holdbackBps > 0
                ? LadderConstants.HoldbackDelivery.Vault
                : LadderConstants.HoldbackDelivery.None,
            tier: inn.tier,
            createSidePool: true,
            sidePoolBps: inn.sidePoolBps,
            stonkzRefPriceWad: 2.5e11, // pair-wei per STONKZ token, WAD
            walletCapBps: inn.walletCapBps,
            sizeBonusBps: inn.sizeBonusBps,
            maxUniqueActives: 300,
            pairToken: address(0),
            creator: CREATOR,
            treasury: TREASURY,
            vaultRef: vault,
            settlement: address(0)
        });
    }

    function _deploy(LadderTypes.Inputs memory inn) internal {
        address vault = inn.holdbackBps > 0 ? address(mockVault) : address(0);
        auction = new StonkzLadderAuction(_params(inn, vault));
        auction.setSettlement(settlement);
        auction.start();
    }

    function _placeAll(LadderTypes.Bid[] memory bids) internal {
        for (uint256 i; i < bids.length; i++) {
            address w = bids[i].wallet;
            vm.deal(w, bids[i].size + 1 ether);
            vm.prank(w);
            auction.placeBid{value: bids[i].size}(bids[i].size, bids[i].maxPrice);
        }
    }

    function _replay(string memory file)
        internal
        returns (LadderTypes.Inputs memory inn, LadderTypes.Outputs memory exp)
    {
        string memory json = _loadRaw(file);
        inn = loadInputs(json);
        LadderTypes.Bid[] memory bids = loadBids(json);
        exp = loadOutputs(json);
        LadderTypes.PathRow[] memory path = loadPath(json);

        _deploy(inn);
        _placeAll(bids);
        auction.clearAllForTest();

        // Build got outputs for A1–A5
        (uint256 toLP, uint256 toTreasury, uint256 toCreator) = auction.raiseSplit();
        LadderTypes.RaiseSplit memory split =
            LadderTypes.RaiseSplit({toLP: toLP, toTreasury: toTreasury, toCreator: toCreator});

        LadderTypes.Fill[] memory gotFills = new LadderTypes.Fill[](exp.fills.length);
        for (uint256 i; i < exp.fills.length; i++) {
            address w = exp.fills[i].wallet;
            (uint256 c, uint256 s, uint256 t, uint256 r) = auction.fillOf(w);
            gotFills[i] = LadderTypes.Fill({wallet: w, committed: c, spent: s, tokens: t, refund: r});
        }

        bytes32[] memory gotReasons = new bytes32[](auction.failReasonCount());
        for (uint256 i; i < gotReasons.length; i++) {
            gotReasons[i] = auction.failReasons(i);
        }

        LadderTypes.PathRow[] memory gotPath = new LadderTypes.PathRow[](path.length);
        for (uint16 p = 1; p <= LadderConstants.DESIGN_N; p++) {
            gotPath[p - 1] = LadderTypes.PathRow({
                period: p,
                price: auction.pathPrice(p),
                offered: auction.pathOffered(p),
                sold: auction.pathSold(p),
                phase: bytes32(0)
            });
        }

        assertA1_raiseSplit(split, auction.raised(), exp.raiseSplit);
        assertA2_fillConservation(gotFills, exp.fills, auction.raised(), auction.committedTotal());
        // A3: typed gate names (raise / lpHealth), not sim prose strings.
        assertEq(auction.graduated(), exp.graduated, "A3 graduated");
        if (exp.graduated) {
            assertEq(gotReasons.length, 0, "A3: no failReasons when graduated");
        } else {
            assertTrue(gotReasons.length > 0, "A3: must name failing gate");
            // Vector 01/10 are raise-fail; health-only covered in dedicated test.
            bool sawRaise;
            for (uint256 i; i < gotReasons.length; i++) {
                if (gotReasons[i] == keccak256("raise")) sawRaise = true;
            }
            if (exp.failReasons.length > 0) {
                // Sim prose mentions raised/threshold ⇒ expect raise gate.
                assertTrue(sawRaise, "A3: raise gate");
            }
        }
        assertA4_lpHealth(auction.graduated(), auction.lpHealth(), exp.lpHealthFloor);
        // Also check observed health vs vector when graduated
        if (exp.graduated) {
            assertApproxEqAbs(auction.lpHealth(), exp.lpHealth, LadderTolerance.fracTol(exp.lpHealth), "lpH vs vec");
        }
        assertA5_rungGrid(gotPath, inn.floorMcap, inn.supply, inn.rungIntervalUsd);

        assertApproxEqAbs(auction.price(), exp.clearingPrice, 1, "clearP");
        assertApproxEqAbs(auction.lpHealth(), exp.lpHealth, LadderTolerance.fracTol(exp.lpHealth), "lpH");
    }

    // ─── Full A1–A5 (all 10; 09 is vault+cashHB replacement) ──────────────

    function test_P3_A1A5_01() public {
        _replay("01-thin-book-fails.json");
    }

    function test_P3_A1A5_02() public {
        _replay("02-god-2p5k-at-bar.json");
    }

    function test_P3_A1A5_03() public {
        _replay("03-god-5k-oversub.json");
    }

    function test_P3_A1A5_04() public {
        _replay("04-4h-5k-at-bar.json");
    }

    function test_P3_A1A5_05() public {
        _replay("05-daily-10k-at-bar.json");
    }

    function test_P3_A1A5_06() public {
        _replay("06-daily-20k-heavy.json");
    }

    function test_P3_A1A5_07() public {
        _replay("07-road-40k-at-bar.json");
    }

    function test_P3_A1A5_08() public {
        _replay("08-locked-holdback-60.json");
    }

    /// @dev Exclusion-family third leg: VEST/vault 20% + cash holdback 20%. Both extractions verified.
    function test_P3_A1A5_09_vaultAndCashHoldback() public {
        string memory file = "09-vault-holdback-cashhb.json";
        string memory json = _loadRaw(file);
        LadderTypes.Inputs memory inn = loadInputs(json);
        LadderTypes.Outputs memory exp = loadOutputs(json);
        LadderTypes.Bid[] memory bids = loadBids(json);

        // Native pair settlement stamped before the bell (no post-end rewire).
        LadderSettlement nativeSettle =
            new LadderSettlement(IPoolManager(address(pm)), hook, address(0));
        nativeSettle.setStonkzRef(STONKZ);

        StonkzLadderAuction.Params memory p = _params(inn, address(mockVault));
        p.settlement = address(nativeSettle);
        auction = new StonkzLadderAuction(p);
        auction.start();
        for (uint256 i; i < bids.length; i++) {
            address w = bids[i].wallet;
            vm.deal(w, bids[i].size + 1 ether);
            vm.prank(w);
            auction.placeBid{value: bids[i].size}(bids[i].size, bids[i].maxPrice);
        }
        auction.clearAllForTest();

        assertTrue(auction.graduated(), "09 graduated");
        assertApproxEqAbs(auction.lpHealth(), 0.3546e18, 0.001e18, "lpHealth ~0.3546");
        assertGe(auction.lpHealth(), 0.35e18, "vs floor");
        assertEq(inn.holdbackBps, 2000, "vault 20%");
        assertEq(inn.cashHoldbackBps, 2000, "cash HB 20%");
        assertEq(exp.lockedTokens, 200_000_000 ether, "locked 200M");
        assertEq(exp.mcapFDV, 62_000 ether, "FDV 62k");
        assertEq(exp.mcapCirculating, 49_600 ether, "circ 49.6k");

        uint256 unsold = inn.auctionSupply - auction.soldTokens();
        uint256 side = (unsold * inn.sidePoolBps) / 10_000;
        uint256 mainAsk = unsold - side;
        uint256 vaultAmt = (inn.supply * inn.holdbackBps) / 10_000;

        uint256 creatorBefore = CREATOR.balance;
        uint256 treasuryBefore = TREASURY.balance;
        uint256 vaultTokBefore = tok.balanceOf(address(mockVault));
        tok.mint(address(nativeSettle), vaultAmt + mainAsk + side);

        auction.settle(address(tok));

        (uint256 toLP, uint256 toTreasury, uint256 toCreator) = auction.raiseSplit();
        assertEq(nativeSettle.toLP() + nativeSettle.toTreasury() + nativeSettle.toCreator(), auction.raised(), "A1 exact");
        assertEq(nativeSettle.toTreasury(), toTreasury);
        assertEq(nativeSettle.toCreator(), toCreator);
        assertEq(nativeSettle.toLP(), toLP);
        assertEq(CREATOR.balance - creatorBefore, toCreator, "cash holdback to creator");
        assertEq(TREASURY.balance - treasuryBefore, toTreasury, "carve to treasury");
        assertEq(tok.balanceOf(address(mockVault)) - vaultTokBefore, vaultAmt, "vault token holdback");
        assertEq(mockVault.custody(address(tok)), vaultAmt, "vault custody");
        assertTrue(hook.registered(address(tok)), "hook registered like Express");
        assertTrue(nativeSettle.askTickLower() < nativeSettle.askTickUpper(), "ask range");
        assertTrue(nativeSettle.cashTickLower() < nativeSettle.cashTickUpper(), "cash range");
    }

    function test_P3_A1A5_10() public {
        _replay("10-wallet-cap-binding.json");
    }

    // ─── Gate naming ──────────────────────────────────────────────────────

    function test_P3_gate_raiseFail_vector01() public {
        _replay("01-thin-book-fails.json");
        assertFalse(auction.graduated());
        assertEq(auction.failReasonCount(), 1);
        assertEq(auction.failReasons(0), keccak256("raise"));
    }

    function test_P3_gate_healthFail_08shape() public {
        // 08-shaped: daily + vault holdback (circFrac=0.4). Absurd health floor.
        // Raise must clear even if price sticks near floor (auctionSupply*floorPrice > threshold).
        LadderTypes.Inputs memory inn = loadInputs(_loadRaw("08-locked-holdback-60.json"));
        StonkzLadderAuction.Params memory p = _params(inn, address(mockVault));
        p.lpHealthTargetWad = 50e18; // 5000% — impossible
        p.floorMcap = 5_000 ether; // threshold = 3_000; auctionSupply*floorPrice = 400M*5e-6 = $2k — still low
        // Use full supply as auction so floor stick still clears raise: 1e9 * 5e-6 = $5k > $3k.
        p.auctionSupply = inn.supply;
        p.holdbackBps = 6000; // keep circFrac=0.4 (08 shape)
        p.walletCapBps = 1000;
        auction = new StonkzLadderAuction(p);
        auction.start();
        for (uint256 i; i < 30; i++) {
            address w = address(uint160(0xC000 + i));
            uint256 size = 500 ether;
            vm.deal(w, size);
            vm.prank(w);
            auction.placeBid{value: size}(size, 1 ether);
        }
        auction.clearAllForTest();
        assertTrue(auction.raised() >= auction.threshold(), "raise should pass");
        assertFalse(auction.graduated(), "health fail");
        assertTrue(_hasReason(keccak256("lpHealth")), "must name lpHealth gate");
        // Vector 01 names raise — this names health (the regression pair).
        assertFalse(_hasReason(keccak256("raise")), "raise gate must not fire");
    }

    function _hasReason(bytes32 r) internal view returns (bool) {
        for (uint256 i; i < auction.failReasonCount(); i++) {
            if (auction.failReasons(i) == r) return true;
        }
        return false;
    }

    // ─── Carve stamp survives default change ──────────────────────────────

    function test_P3_carveBps_stampSurvivesDefaultChange() public {
        StonkzLadderAuction.Params memory p = StonkzLadderAuction.Params({
            supply: 1_000_000_000 ether,
            auctionSupply: 1_000_000_000 ether,
            floorMcap: 2_500 ether,
            duration: LadderConstants.GOD_DURATION,
            lpShareWad: 0.91e18,
            lpHealthTargetWad: 0.25e18,
            carveBps: type(uint16).max, // use factory default
            cashHoldbackBps: 500,
            holdbackBps: 0,
            holdbackDelivery: LadderConstants.HoldbackDelivery.None,
            tier: LadderTypes.Tier.God,
            createSidePool: true,
            sidePoolBps: 500,
            stonkzRefPriceWad: 2.5e11, // pair-wei per STONKZ token, WAD
            walletCapBps: 500,
            sizeBonusBps: 1000,
            maxUniqueActives: 300,
            pairToken: address(0),
            creator: CREATOR,
            treasury: TREASURY,
            vaultRef: address(0),
            settlement: address(0)
        });
        assertEq(factory.defaultCarveBps(), 400);
        StonkzLadderAuction a = factory.file(p);
        assertEq(a.carveBps(), 400, "stamped 400");

        factory.setDefaultCarveBps(700);
        assertEq(a.carveBps(), 400, "stamp survives default change");

        p.carveBps = type(uint16).max;
        StonkzLadderAuction b = factory.file(p);
        assertEq(b.carveBps(), 700, "new filing gets new default");
    }

    // ─── MIN_ASK_BPS ──────────────────────────────────────────────────────

    function test_P3_minAskBps_reverts() public {
        // Graduate with nearly full sell so unsold ask < 5% supply.
        StonkzLadderAuction.Params memory p = StonkzLadderAuction.Params({
            supply: 100 ether,
            auctionSupply: 100 ether,
            floorMcap: 10 ether,
            duration: LadderConstants.GOD_DURATION,
            lpShareWad: 0.91e18,
            lpHealthTargetWad: 0.01e18, // easy health
            carveBps: 400,
            cashHoldbackBps: 500,
            holdbackBps: 0,
            holdbackDelivery: LadderConstants.HoldbackDelivery.None,
            tier: LadderTypes.Tier.God,
            createSidePool: true,
            sidePoolBps: 500,
            stonkzRefPriceWad: 2.5e11, // pair-wei per STONKZ token, WAD
            walletCapBps: 1000,
            sizeBonusBps: 0,
            maxUniqueActives: 300,
            pairToken: address(0),
            creator: CREATOR,
            treasury: TREASURY,
            vaultRef: address(0),
            settlement: address(0)
        });
        LadderSettlement s = new LadderSettlement(IPoolManager(address(pm)), hook, address(0));
        // Direct probe: unsold 4; side 5% → main ask 3.8 < 5% of supply (5).
        vm.expectRevert(LadderSettlement.MinAsk.selector);
        s.settle{value: 10 ether}(
            LadderSettlement.SettleArgs({
                graduated: true,
                raised: 10 ether,
                supply: 100 ether,
                auctionSupply: 100 ether,
                soldTokens: 96 ether,
                printPrice: 1 ether,
                floorPrice: 0.1 ether,
                carveBps: 400,
                cashHoldbackBps: 500,
                holdbackBps: 0,
                createSidePool: true,
                sidePoolBps: 500,
                stonkzRefPriceWad: 2.5e11, // pair-wei per STONKZ token, WAD
                liquidityLocked: true,
                unlockRecipient: CREATOR,
                vaultRef: address(0),
                creator: CREATOR,
                treasury: TREASURY,
                userToken: address(tok)
            })
        );
    }

    function test_P3_hookRegister_matchesExpressPattern() public {
        string memory json = _loadRaw("02-god-2p5k-at-bar.json");
        LadderTypes.Inputs memory inn = loadInputs(json);
        LadderTypes.Bid[] memory bids = loadBids(json);

        LadderSettlement s = new LadderSettlement(IPoolManager(address(pm)), hook, address(0));
        s.setStonkzRef(STONKZ);
        StonkzLadderAuction.Params memory p = _params(inn, address(0));
        p.settlement = address(s);
        auction = new StonkzLadderAuction(p);
        auction.start();
        for (uint256 i; i < bids.length; i++) {
            address w = bids[i].wallet;
            vm.deal(w, bids[i].size + 1 ether);
            vm.prank(w);
            auction.placeBid{value: bids[i].size}(bids[i].size, bids[i].maxPrice);
        }
        auction.clearAllForTest();

        uint256 unsold = auction.auctionSupply() - auction.soldTokens();
        tok.mint(address(s), unsold + 1 ether);
        assertGe(address(auction).balance, auction.raised());
        auction.settle(address(tok));
        assertTrue(hook.registered(address(tok)));
        (,, uint24 fee,, address hooksAddr) = s.mainPoolKey();
        assertEq(hooksAddr, address(hook), "hooks on PoolKey");
        assertEq(uint256(fee), 0, "main LP fee 0 pips");
    }

    function test_P3_setSettlement_frozenAfterBell() public {
        LadderTypes.Inputs memory inn = loadInputs(_loadRaw("02-god-2p5k-at-bar.json"));
        _deploy(inn);
        // End with no bids — still freezes settlement wiring.
        vm.warp(auction.startTime() + auction.duration() + 1);
        auction.clearAllForTest();
        assertTrue(auction.done());

        LadderSettlement s2 = new LadderSettlement(IPoolManager(address(pm)), hook, address(0));
        vm.expectRevert(StonkzLadderAuction.SettlementFrozenAfterBell.selector);
        auction.setSettlement(s2);
    }
}

contract MockLaunchToken {
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
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}
