// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {stdJson} from "forge-std/StdJson.sol";
import {FactoryVanity} from "../FactoryVanity.sol";
import {LadderVectorLoader} from "./LadderVectorLoader.sol";
import {LadderAsserts} from "./LadderAsserts.sol";
import {LadderTypes} from "../../src/ladder/LadderTypes.sol";
import {LadderConstants} from "../../src/ladder/LadderConstants.sol";
import {LadderTolerance} from "./LadderTolerance.sol";
import {StonkzLadderAuction} from "../../src/ladder/StonkzLadderAuction.sol";
import {StonkzLadderFactory} from "../../src/ladder/StonkzLadderFactory.sol";
import {MockVault} from "./MockVault.sol";

/// @title LadderPhase2 — bids/fills A2; vault-only holdback guards (docs/09 + circFrac ruling)
contract LadderPhase2 is LadderVectorLoader, LadderAsserts, FactoryVanity {
    using stdJson for string;

    StonkzLadderAuction internal auction;
    StonkzLadderFactory internal factory;
    MockVault internal mockVault;

    function setUp() public {
        mockVault = new MockVault();
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
            refPriceWad: 2.5e11, // pair-wei per STONKZ token, WAD
            walletCapBps: inn.walletCapBps,
            sizeBonusBps: inn.sizeBonusBps,
            maxUniqueActives: 300,
            pairToken: address(0),
            creator: address(0xCE0),
            treasury: address(0x7A5E),
            vaultRef: vault,
            settlement: address(0)
        });
    }

    function _deploy(LadderTypes.Inputs memory inn) internal {
        address vault = inn.holdbackBps > 0 ? address(mockVault) : address(0);
        auction = new StonkzLadderAuction(_params(inn, vault));
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

    function _runA2(string memory file) internal {
        string memory json = _loadRaw(file);
        LadderTypes.Inputs memory inn = loadInputs(json);
        LadderTypes.Bid[] memory bids = loadBids(json);
        LadderTypes.Outputs memory exp = loadOutputs(json);

        _deploy(inn);
        _placeAll(bids);
        auction.clearAllForTest();

        LadderTypes.Fill[] memory got = new LadderTypes.Fill[](exp.fills.length);
        for (uint256 i; i < exp.fills.length; i++) {
            address w = exp.fills[i].wallet;
            (uint256 committed, uint256 spent, uint256 tokens, uint256 refund) = auction.fillOf(w);
            got[i] = LadderTypes.Fill({wallet: w, committed: committed, spent: spent, tokens: tokens, refund: refund});
        }

        assertA2_fillConservation(got, exp.fills, auction.raised(), auction.committedTotal());
        assertApproxEqAbs(auction.price(), exp.clearingPrice, 1, "clearingPrice");
        assertApproxEqAbs(auction.raised(), exp.raised, LadderTolerance.moneyTol(exp.raised), "raised");
    }

    function test_P2_A2_01_thin() public {
        _runA2("01-thin-book-fails.json");
    }

    function test_P2_A2_02_god() public {
        _runA2("02-god-2p5k-at-bar.json");
    }

    function test_P2_A2_03_oversub() public {
        _runA2("03-god-5k-oversub.json");
    }

    function test_P2_A2_04_4h() public {
        _runA2("04-4h-5k-at-bar.json");
    }

    function test_P2_A2_05_daily() public {
        _runA2("05-daily-10k-at-bar.json");
    }

    function test_P2_A2_06_heavy() public {
        _runA2("06-daily-20k-heavy.json");
    }

    function test_P2_A2_07_road() public {
        _runA2("07-road-40k-at-bar.json");
    }

    function test_P2_A2_08_vaultHoldback60() public {
        _runA2("08-locked-holdback-60.json");
    }

    function test_P2_A2_09_vaultHoldbackCashHb() public {
        _runA2("09-vault-holdback-cashhb.json");
    }

    function test_P2_A2_10_capBinding() public {
        _runA2("10-wallet-cap-binding.json");
    }

    function test_P2_holdbackFiling_revertsWithoutVault_succeedsAfterSet() public {
        factory = new StonkzLadderFactory();
        factory.setCarveTreasury(address(0x7A5E));
        vm.etch(address(0x4663), hex"00");
        factory.setSideTokenRef(address(0x4663));
        LadderTypes.Inputs memory inn = loadInputs(_loadRaw("08-locked-holdback-60.json"));
        StonkzLadderAuction.Params memory p = _params(inn, address(0));
        p.vaultRef = address(0);

        vm.expectRevert(StonkzLadderFactory.VaultRequiredForHoldback.selector);
        factory.file(p, bytes32(0));

        factory.setVaultRef(address(mockVault));
        StonkzLadderAuction a = _file(factory, p);
        assertEq(a.vaultRef(), address(mockVault));
        assertEq(a.holdbackBps(), 6000);
        assertEq(a.circFrac(), 0.4e18);
    }

    function test_P2_setVaultRef_rejectsEOA() public {
        factory = new StonkzLadderFactory();
        factory.setCarveTreasury(address(0x7A5E));
        vm.expectRevert(StonkzLadderFactory.VaultRefNotContract.selector);
        factory.setVaultRef(address(0xBEEF));
    }

    function test_P2_tierCeiling_god41Reverts_40Files() public {
        factory = new StonkzLadderFactory();
        factory.setCarveTreasury(address(0x7A5E));
        vm.etch(address(0x4663), hex"00");
        factory.setSideTokenRef(address(0x4663));
        factory.setVaultRef(address(mockVault));
        LadderTypes.Inputs memory inn = loadInputs(_loadRaw("02-god-2p5k-at-bar.json"));
        StonkzLadderAuction.Params memory p = _params(inn, address(mockVault));
        p.tier = LadderTypes.Tier.God;
        p.holdbackDelivery = LadderConstants.HoldbackDelivery.Vault;
        p.holdbackBps = 4100;
        p.auctionSupply = (inn.supply * 5900) / 10_000;

        vm.expectRevert(StonkzLadderFactory.HoldbackCeiling.selector);
        factory.file(p, bytes32(0));

        p.holdbackBps = 4000;
        p.auctionSupply = (inn.supply * 6000) / 10_000;
        StonkzLadderAuction a = _file(factory, p);
        assertEq(a.holdbackBps(), 4000);
    }

    function test_P2_settlement_depositsHoldbackToVault() public {
        MockERC20 tok = new MockERC20();
        factory = new StonkzLadderFactory();
        factory.setCarveTreasury(address(0x7A5E));
        vm.etch(address(0x4663), hex"00");
        factory.setSideTokenRef(address(0x4663));
        factory.setVaultRef(address(mockVault));

        StonkzLadderAuction.Params memory p = StonkzLadderAuction.Params({
            supply: 1_000_000_000 ether,
            auctionSupply: 400_000_000 ether,
            floorMcap: 2_500 ether,
            duration: LadderConstants.GOD_DURATION,
            lpShareWad: 0.91e18,
            lpHealthTargetWad: 0.25e18,
            carveBps: 400,
            cashHoldbackBps: 500,
            holdbackBps: 4000,
            holdbackDelivery: LadderConstants.HoldbackDelivery.Vault,
            tier: LadderTypes.Tier.God,
            createSidePool: true,
            sidePoolBps: 500,
            refPriceWad: 2.5e11, // pair-wei per STONKZ token, WAD
            walletCapBps: 1000,
            sizeBonusBps: 1000,
            maxUniqueActives: 300,
            pairToken: address(0),
            creator: address(0xCE0),
            treasury: address(0x7A5E),
            vaultRef: address(0),
            settlement: address(0)
        });
        auction = _file(factory, p);
        auction.start();

        for (uint256 i; i < 10; i++) {
            address w = address(uint160(0xA100 + i));
            uint256 size = 500 ether;
            vm.deal(w, size);
            vm.prank(w);
            auction.placeBid{value: size}(size, 1 ether);
        }
        auction.clearAllForTest();
        assertTrue(auction.graduated(), "must graduate for deposit test");

        uint256 amt = auction.holdbackAmount();
        assertEq(amt, (p.supply * 4000) / 10_000);
        tok.mint(address(auction), amt);
        auction.depositHoldback(address(tok));
        assertEq(tok.balanceOf(address(mockVault)), amt);
        assertEq(mockVault.custody(address(tok)), amt);
        assertTrue(auction.holdbackDeposited());
    }

    function test_P2_bid_min5_and_maxPriceRevert() public {
        LadderTypes.Inputs memory inn = loadInputs(_loadRaw("02-god-2p5k-at-bar.json"));
        _deploy(inn);
        address a = address(0xA);
        vm.deal(a, 10 ether);
        vm.prank(a);
        vm.expectRevert(StonkzLadderAuction.MinBid.selector);
        auction.placeBid{value: 4 ether}(4 ether, 1 ether);

        _deploy(inn);
        vm.deal(a, 100 ether);
        vm.prank(a);
        auction.placeBid{value: 50 ether}(50 ether, 1 ether);
        vm.warp(block.timestamp + 4);
        auction.poke();
        uint256 live = auction.price();
        if (live > inn.floorPrice) {
            vm.prank(a);
            vm.expectRevert(StonkzLadderAuction.MaxPriceBelowLive.selector);
            auction.placeBid{value: 5 ether}(5 ether, live - 1);
        }
    }
}

contract MockERC20 {
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
