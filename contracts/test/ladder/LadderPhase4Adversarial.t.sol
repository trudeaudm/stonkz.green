// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LadderPhase4Base} from "./LadderPhase4Base.sol";
import {StonkzLadderAuction} from "../../src/ladder/StonkzLadderAuction.sol";
import {LadderConstants} from "../../src/ladder/LadderConstants.sol";
import {LadderTypes} from "../../src/ladder/LadderTypes.sol";

/// @title LadderPhase4Adversarial — docs/09 §9 + vault-holdback/circFrac fuzz
contract LadderPhase4Adversarial is LadderPhase4Base {
    /// @notice Decoy high-max bids inflate liveBudget/Mmax then get priced out.
    function test_P4_decoyHighMax_pricedOut_healthOkIfGraduated() public {
        DeployCfg memory c = _defaultCfg();
        StonkzLadderAuction a = _deploy(c);

        // Real demand — enough to clear raise at god $1500.
        for (uint256 i; i < 10; i++) {
            _bid(a, address(uint160(0xA100 + i)), 200 ether, 1 ether);
        }
        // Decoys: huge maxPrice, large size — inflate liveBudget then strand as price climbs.
        for (uint256 i; i < 5; i++) {
            _bid(a, address(uint160(0xD100 + i)), 5_000 ether, type(uint128).max);
        }
        a.clearAllForTest();
        _assertHealthIfGraduated(a);
        // Decoys should have refund claimable (priced out or unspent).
        uint256 refunds;
        for (uint256 i; i < 5; i++) {
            (, uint256 spent,, uint256 refund) = a.fillOf(address(uint160(0xD100 + i)));
            refunds += refund;
            spent; // silence
        }
        assertTrue(refunds > 0, "decoys should leave claimable refund");
    }

    /// @notice Late whale enters in final periods after shallow book has run.
    function test_P4_lateWhale_finalPeriods_healthOkIfGraduated() public {
        DeployCfg memory c = _defaultCfg();
        StonkzLadderAuction a = _deploy(c);

        for (uint256 i; i < 8; i++) {
            _bid(a, address(uint160(0xA200 + i)), 150 ether, 1 ether);
        }
        // Clear through most of shallow (period ~700 of 1000).
        uint256 t0 = block.timestamp;
        vm.warp(t0 + (LadderConstants.GOD_DURATION * 700) / 1000);
        a.poke();

        // Late whale in finale window.
        _bid(a, address(0xB4A1E), 10_000 ether, 1 ether);
        vm.warp(t0 + LadderConstants.GOD_DURATION);
        a.poke();
        if (!a.done()) a.clearAllForTest();
        _assertHealthIfGraduated(a);
    }

    /// @notice Split-bid vs single-bid EXACT equivalence (same address = one weight).
    function test_P4_splitBid_vs_singleBid_exactEquivalence() public {
        DeployCfg memory c = _defaultCfg();
        c.sizeBonusBps = 1000;

        // Auction A: single $200 bid
        StonkzLadderAuction single = _deploy(c);
        address trader = address(0xAB1E); // same address → one weight
        // Seed identical background book on both.
        for (uint256 i; i < 5; i++) {
            _bid(single, address(uint160(0xB100 + i)), 100 ether, 1 ether);
        }
        _bid(single, trader, 200 ether, 1 ether);

        // Auction B: two $100 bids from same address
        StonkzLadderAuction split = _deploy(c);
        for (uint256 i; i < 5; i++) {
            _bid(split, address(uint160(0xB100 + i)), 100 ether, 1 ether);
        }
        _bid(split, trader, 100 ether, 1 ether);
        _bid(split, trader, 100 ether, 1 ether);

        single.clearAllForTest();
        split.clearAllForTest();

        (uint256 c1, uint256 s1, uint256 t1, uint256 r1) = single.fillOf(trader);
        (uint256 c2, uint256 s2, uint256 t2, uint256 r2) = split.fillOf(trader);
        assertEq(c1, c2, "committed");
        assertEq(s1, s2, "spent EXACT");
        assertEq(t1, t2, "tokens EXACT");
        assertEq(r1, r2, "refund EXACT");
        assertEq(single.raised(), split.raised(), "raised EXACT");
        assertEq(single.price(), split.price(), "clearing price EXACT");
    }

    /// @notice Property fuzz: no (holdback, cashHB, strategy) graduates with lpHealth < floor.
    ///         holdbackPct swept across [0, tier ceiling] — circFrac load (vector 09 margin).
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_P4_noGraduateBelowFloor(
        uint8 tierRaw,
        uint16 holdbackBpsRaw,
        uint16 cashHbRaw,
        uint8 strategy,
        uint256 seed
    ) public {
        LadderTypes.Tier tier = LadderTypes.Tier(uint8(bound(tierRaw, 0, 3)));
        uint16 ceil = LadderConstants.holdbackCeilingBps(uint8(tier));
        uint16 holdbackBps = uint16(bound(holdbackBpsRaw, 0, ceil));
        uint16 cashHb = uint16(bound(cashHbRaw, 0, LadderConstants.CASH_HOLDBACK_BPS_MAX));
        // Keep carve+cashHB <= 10000
        if (uint256(cashHb) + LadderConstants.DEFAULT_CARVE_BPS > 10_000) {
            cashHb = 10_000 - LadderConstants.DEFAULT_CARVE_BPS;
        }

        DeployCfg memory c = _defaultCfg();
        c.tier = tier;
        c.holdbackBps = holdbackBps;
        c.cashHoldbackBps = cashHb;
        c.floorMcap = tier == LadderTypes.Tier.God
            ? 2_500 ether
            : (tier == LadderTypes.Tier.H4 ? 5_000 ether : (tier == LadderTypes.Tier.Daily ? 10_000 ether : 20_000 ether));
        c.walletCapBps = 1000;
        c.maxUniqueActives = 50; // fuzz budget — property is mechanism not gas

        StonkzLadderAuction a = _deploy(c);
        uint8 strat = uint8(bound(strategy, 0, 3));
        _applyStrategy(a, strat, seed);
        if (!a.done()) a.clearAllForTest();

        if (a.graduated()) {
            assertGe(a.lpHealth(), a.lpHealthTargetWad(), "FUZZ: graduated with lpHealth < tierFloor");
            // Belt: also vs constant table
            assertGe(a.lpHealth(), _tierFloor(tier), "FUZZ: below table floor");
        }
    }

    /// @notice Focused vault-holdback sweep at daily ceiling band (tight circFrac margin).
    function test_P4_vaultHoldbackSweep_daily_neverBelowFloor() public {
        uint16[7] memory hb = [uint16(0), 1000, 2000, 3000, 4000, 5000, 6000];
        for (uint256 i; i < hb.length; i++) {
            DeployCfg memory c = _defaultCfg();
            c.tier = LadderTypes.Tier.Daily;
            c.floorMcap = 10_000 ether;
            c.holdbackBps = hb[i];
            c.cashHoldbackBps = 2000; // vector-09-like cash HB
            c.walletCapBps = 1000;
            StonkzLadderAuction a = _deploy(c);
            // Mixed book: decoys + real + late-ish whale
            for (uint256 j; j < 12; j++) {
                _bid(a, address(uint160(0xE100 + j)), 800 ether, 1 ether);
            }
            for (uint256 j; j < 3; j++) {
                _bid(a, address(uint160(0xF100 + j)), 3_000 ether, type(uint128).max);
            }
            a.clearAllForTest();
            _assertHealthIfGraduated(a);
        }
    }

    function _applyStrategy(StonkzLadderAuction a, uint8 strat, uint256 seed) internal {
        uint256 n = 8 + (seed % 8); // 8..15 wallets
        if (strat == 0) {
            // Honest book
            for (uint256 i; i < n; i++) {
                _bid(a, address(uint160(0x1000 + i)), 200 ether + (seed % 300 ether), 1 ether);
            }
        } else if (strat == 1) {
            // Decoy-heavy
            for (uint256 i; i < n / 2; i++) {
                _bid(a, address(uint160(0x2000 + i)), 150 ether, 1 ether);
            }
            for (uint256 i; i < n / 2; i++) {
                _bid(a, address(uint160(0x3000 + i)), 2_000 ether, type(uint128).max);
            }
        } else if (strat == 2) {
            // Split bids same addresses
            for (uint256 i; i < n; i++) {
                address w = address(uint160(0x4000 + i));
                _bid(a, w, 100 ether, 1 ether);
                _bid(a, w, 100 ether, 1 ether);
            }
        } else {
            // Early small + late whale
            for (uint256 i; i < n; i++) {
                _bid(a, address(uint160(0x5000 + i)), 80 ether, 1 ether);
            }
            uint256 t0 = block.timestamp;
            vm.warp(t0 + (_duration(a.tier()) * 850) / 1000);
            a.poke();
            _bid(a, address(0x1A7E), 8_000 ether, 1 ether);
            vm.warp(t0 + _duration(a.tier()));
            a.poke();
        }
    }
}
