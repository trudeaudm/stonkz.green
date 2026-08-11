// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {stdJson} from "forge-std/StdJson.sol";
import {LadderVectorLoader} from "./LadderVectorLoader.sol";
import {LadderAsserts} from "./LadderAsserts.sol";
import {LadderTypes} from "../../src/ladder/LadderTypes.sol";
import {LadderConstants} from "../../src/ladder/LadderConstants.sol";
import {StonkzLadderAuction} from "../../src/ladder/StonkzLadderAuction.sol";
import {LadderConstants} from "../../src/ladder/LadderConstants.sol";
import {MockVault} from "./MockVault.sol";

/// @title LadderPhase1 — rungs, periods, liveBudget; A5 on at-bar vectors (docs/09)
contract LadderPhase1 is LadderVectorLoader, LadderAsserts {
    using stdJson for string;

    StonkzLadderAuction internal auction;
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

    function _deploy(LadderTypes.Inputs memory inn) internal {
        address vault = inn.holdbackBps > 0 ? address(mockVault) : address(0);
        auction = new StonkzLadderAuction(
            StonkzLadderAuction.Params({
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
            })
        );
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

    function _replayPath(string memory file)
        internal
        returns (LadderTypes.PathRow[] memory got, LadderTypes.PathRow[] memory exp, LadderTypes.Inputs memory inn)
    {
        string memory json = _loadRaw(file);
        inn = loadInputs(json);
        LadderTypes.Bid[] memory bids = loadBids(json);
        exp = loadPath(json);
        _deploy(inn);
        _placeAll(bids);

        auction.clearAllForTest();
        got = new LadderTypes.PathRow[](LadderConstants.DESIGN_N);
        for (uint16 p = 1; p <= LadderConstants.DESIGN_N; p++) {
            got[p - 1] = LadderTypes.PathRow({
                period: p,
                price: auction.pathPrice(p),
                offered: auction.pathOffered(p),
                sold: auction.pathSold(p),
                phase: bytes32(0)
            });
        }
    }

    function _assertPathPrices(LadderTypes.PathRow[] memory got, LadderTypes.PathRow[] memory exp) internal pure {
        assertEq(got.length, exp.length, "path len");
        for (uint256 i; i < got.length; i++) {
            assertEq(got[i].price, exp[i].price, "path price exact");
        }
    }

    function test_P1_A5_and_path_02_god_atBar() public {
        (LadderTypes.PathRow[] memory got, LadderTypes.PathRow[] memory exp, LadderTypes.Inputs memory inn) =
            _replayPath("02-god-2p5k-at-bar.json");
        assertA5_rungGrid(got, inn.floorMcap, inn.supply, inn.rungIntervalUsd);
        _assertPathPrices(got, exp);
    }

    function test_P1_A5_and_path_04_4h_atBar() public {
        (LadderTypes.PathRow[] memory got, LadderTypes.PathRow[] memory exp, LadderTypes.Inputs memory inn) =
            _replayPath("04-4h-5k-at-bar.json");
        assertA5_rungGrid(got, inn.floorMcap, inn.supply, inn.rungIntervalUsd);
        _assertPathPrices(got, exp);
    }

    function test_P1_A5_and_path_05_daily_atBar() public {
        (LadderTypes.PathRow[] memory got, LadderTypes.PathRow[] memory exp, LadderTypes.Inputs memory inn) =
            _replayPath("05-daily-10k-at-bar.json");
        assertA5_rungGrid(got, inn.floorMcap, inn.supply, inn.rungIntervalUsd);
        _assertPathPrices(got, exp);
    }

    function test_P1_A5_and_path_07_road_atBar() public {
        (LadderTypes.PathRow[] memory got, LadderTypes.PathRow[] memory exp, LadderTypes.Inputs memory inn) =
            _replayPath("07-road-40k-at-bar.json");
        assertA5_rungGrid(got, inn.floorMcap, inn.supply, inn.rungIntervalUsd);
        _assertPathPrices(got, exp);
    }

    function test_P1_liveBudget_capRoomClamp() public {
        // Vector 10 shape: 1% wallet cap binds liveBudget contributions.
        string memory json = _loadRaw("10-wallet-cap-binding.json");
        LadderTypes.Inputs memory inn = loadInputs(json);
        LadderTypes.Bid[] memory bids = loadBids(json);
        _deploy(inn);
        _placeAll(bids);
        uint256 live = auction.liveBudget();
        // Without clamp, live ≈ sum of budgets; with 1% cap at floor price, each wallet
        // contributes at most capTokens * floorPrice.
        uint256 capTok = (inn.auctionSupply * inn.walletCapBps) / 10_000;
        uint256 capCash = (capTok * auction.price()) / 1e18;
        uint256 uncapped;
        for (uint256 i; i < bids.length; i++) {
            uncapped += bids[i].size;
        }
        assertTrue(live < uncapped, "cap must bind vs raw capital");
        assertTrue(live <= bids.length * capCash, "per-wallet cap room");
    }

    function test_P1_zeroSale_doesNotAdvance() public {
        // After the book stops clearing, price stays flat (docs/09 §1: advance only if sold > 0).
        (LadderTypes.PathRow[] memory got,,) = _replayPath("02-god-2p5k-at-bar.json");
        uint256 finalP = got[got.length - 1].price;
        // Vector 02 pins at rung 6 (mcap $8500); a long flat tail must exist.
        uint256 flat = 0;
        for (uint256 i; i < got.length; i++) {
            if (got[i].price == finalP) flat++;
            if (got[i].sold == 0) {
                assertEq(got[i].price, finalP, "zero-sale period must not have advanced");
            }
        }
        assertTrue(flat > 100, "expected long flat price tail");
        assertEq(finalP, 8_500_000_000_000, "clearing price $8500 mcap");
    }
}
