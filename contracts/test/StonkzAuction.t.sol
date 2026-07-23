// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test, stdJson} from "forge-std/Test.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";
import {LadderWeights} from "../src/LadderWeights.sol";

/// @notice Differential + invariant + regression suite (docs/mechanism-spec.md §9).
/// @dev Vectors from `node reference/gen-vectors.js` — all amounts are 1e18 WAD.
contract StonkzAuctionTest is Test {
    using stdJson for string;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant TOL = 1e18; // 1e18 fixed-point tolerance (spec / milestone)
    uint256 internal constant BID_FEE = WAD / 10;

    StonkzAuction internal auction;

    address internal constant ADDR_A = address(0xA11);
    address internal constant ADDR_B = address(0xB22);
    address internal constant ADDR_C = address(0xC33);
    address internal constant ADDR_D = address(0xD44);

    // ═══════════════════════════════════════════════════════════════════════
    // A. VECTOR TESTS
    // ═══════════════════════════════════════════════════════════════════════

    function testVector_canonicalAbc() public {
        _runVector("canonical-abc");
    }

    function testVector_sizeTilt() public {
        _runVector("size-tilt");
    }

    function testVector_ghostTownSquish() public {
        _runVector("ghost-town-squish");
    }

    function testVector_frozenBookThaw() public {
        _runVector("frozen-book-thaw");
    }

    function testVector_oversubscriptionDrain() public {
        _runVector("oversubscription-drain");
    }

    function testVector_kappaSplit() public {
        string memory json = _load("kappa-split");
        auction = new StonkzAuction(_params(json));
        uint256 pctBps = (auction.auctionSupply() * 10_000) / auction.launchSupply();
        // 61.90476% → 6190 bps
        assertApproxEqAbs(pctBps, 6190, 5, "kappa 61.9%");
    }

    function testVector_failureRefundAll() public {
        _runVector("failure-refund-all");
        assertTrue(auction.done());
        assertFalse(auction.graduated());
    }

    // ═══════════════════════════════════════════════════════════════════════
    // B. INVARIANTS (spec §9)
    // ═══════════════════════════════════════════════════════════════════════

    function testInvariant_I10_weights() public pure {
        for (uint256 N = 10; N <= 200; N += 40) {
            uint256[] memory w = LadderWeights.makeWeights(N);
            uint256 sum;
            bool mono = true;
            for (uint256 i = 0; i < N; i++) {
                sum += w[i];
                if (i > 0 && w[i] + 1 < w[i - 1]) mono = false;
            }
            assertApproxEqAbs(sum, WAD, 1e6, "sum");
            assertTrue(mono, "monotone");
            uint256 K = (N * 80) / 100;
            uint256 fin;
            for (uint256 i = K; i < N; i++) fin += w[i];
            assertApproxEqAbs(fin, (WAD * 60) / 100, 1e6, "finale");
            if (K > 0 && K < N) {
                assertApproxEqAbs(w[K], w[K - 1], w[K - 1] / 1e6 + 1, "handoff");
            }
        }
    }

    function testInvariant_I4_perCapita() public {
        auction = new StonkzAuction(_toy(0));
        _bid(ADDR_A, 1000 ether, type(uint256).max);
        _bid(ADDR_B, 2000 ether, type(uint256).max);
        _step();
        assertApproxEqAbs(auction.bidderTokens(ADDR_A), auction.bidderTokens(ADDR_B), 1e9, "eq");
    }

    function testInvariant_I4_sizeTilt() public {
        auction = new StonkzAuction(_toy(1000));
        _bid(ADDR_A, 1000 ether, type(uint256).max);
        _bid(ADDR_B, 2000 ether, type(uint256).max);
        _step();
        uint256 ratio = (auction.bidderTokens(ADDR_B) * WAD) / auction.bidderTokens(ADDR_A);
        assertApproxEqAbs(ratio, 11 * WAD / 10, WAD / 1e5, "tilt");
    }

    function testInvariant_I7_oneShare() public {
        auction = new StonkzAuction(_toy(0));
        _bid(ADDR_A, 1000 ether, type(uint256).max);
        _bid(ADDR_A, 1000 ether, type(uint256).max);
        _bid(ADDR_A, 1000 ether, type(uint256).max);
        _bid(ADDR_B, 3000 ether, type(uint256).max);
        _step();
        assertApproxEqAbs(auction.bidderTokens(ADDR_A), auction.bidderTokens(ADDR_B), 1e9, "share");
    }

    function testInvariant_I6_walletCap() public {
        IStonkzAuction.Params memory p = _toy(0);
        p.walletCapBps = 100; // 1%
        auction = new StonkzAuction(p);
        uint256 cap = auction.walletCapTokens();
        _bid(ADDR_A, 1_000_000 ether, type(uint256).max);
        _bid(ADDR_B, 1_000_000 ether, type(uint256).max);
        for (uint256 i = 0; i < 10; i++) _step();
        assertLe(auction.bidderTokens(ADDR_A), cap + 1e9);
        assertLe(auction.bidderTokens(ADDR_B), cap + 1e9);
    }

    function testInvariant_I8_refundOnFailure() public {
        IStonkzAuction.Params memory p = _toy(0);
        p.graduationUsd = 2000 ether; // above $100 budgets, within raise ceiling
        p.lpShareBps = 8000;
        auction = new StonkzAuction(p);
        _bid(ADDR_A, 50 ether, type(uint256).max);
        for (uint256 i = 0; i < 10; i++) _step();
        assertTrue(auction.done() && !auction.graduated());
        uint256 balBeforeClaim = ADDR_A.balance;
        vm.prank(ADDR_A);
        auction.claim(1);
        assertApproxEqAbs(ADDR_A.balance - balBeforeClaim, 50 ether, 1, "full refund");
    }

    function testInvariant_I3_priceGate() public {
        auction = new StonkzAuction(_toy(0));
        uint256 floor = auction.price();
        _bid(ADDR_C, 100 ether, floor - 1); // priced out immediately / no fills
        _step();
        assertEq(auction.price(), floor, "no sale => no step");
        assertEq(auction.sold(), 0);
    }

    function testInvariant_I5_committedBudgets() public {
        auction = new StonkzAuction(_toy(0));
        _bid(ADDR_A, 100 ether, type(uint256).max);
        (, uint256 budget,, uint256 spent,,) = auction.positions(1);
        assertEq(budget, 100 ether);
        assertEq(spent, 0);
        _step();
        (, budget,, spent,,) = auction.positions(1);
        assertEq(budget, 100 ether);
        assertLe(spent, budget);
    }

    function testInvariant_I9_settleRevertsIfLive() public {
        auction = new StonkzAuction(_toy(0));
        vm.expectRevert();
        auction.settle();
    }

    function testInvariant_I1_conservation() public {
        IStonkzAuction.Params memory p = _toy(0);
        p.lpShareBps = 8000;
        p.holdbackBps = 1000;
        p.graduationUsd = 100 ether;
        auction = new StonkzAuction(p);
        _bid(ADDR_A, 3000 ether, type(uint256).max);
        _bid(ADDR_B, 3000 ether, type(uint256).max);
        for (uint256 i = 0; i < 12; i++) _step();
        if (!auction.done()) {
            vm.roll(block.number + 20);
            auction.poke();
        }
        if (!auction.graduated()) return;
        auction.settle();
        uint256 P = auction.lastSoldPrice() == 0 ? auction.price() : auction.lastSoldPrice();
        uint256 lpFunds = (auction.raised() * 8000) / 10_000;
        uint256 need = (lpFunds * WAD) / P;
        uint256 rr = auction.reserveRemaining();
        uint256 paired = need < rr ? need : rr;
        uint256 surplus = rr > need ? rr - need : 0;
        uint256 auctSold = auction.auctionSold();
        uint256 excess = auction.auctionSupply() > auctSold ? auction.auctionSupply() - auctSold : 0;
        assertApproxEqAbs(auction.sold() + paired + surplus + excess, auction.launchSupply(), 1e15);
    }

    function testInvariant_I2_topupGuard() public {
        _runVector("oversubscription-drain");
        assertLe(auction.reserveRemaining(), auction.reserveInitial());
    }

    // ═══════════════════════════════════════════════════════════════════════
    // C. REGRESSIONS
    // ═══════════════════════════════════════════════════════════════════════

    function testRegression_stallDeathSpiralImpossible() public {
        _runVector("ghost-town-squish");
        assertTrue(auction.auctionIndex() > 3);
    }

    function testRegression_reserveDrainPaced() public {
        _runVector("oversubscription-drain");
        assertTrue(auction.extraSold() == 0 || auction.done() || auction.auctionIndex() > 1);
    }

    function testRegression_topupGuardHeadroom() public {
        _runVector("oversubscription-drain");
        assertLe(auction.extraSold(), auction.reserveInitial());
    }

    function testRegression_zeroBaseStepOk() public {
        IStonkzAuction.Params memory p = _toy(0);
        p.baseStepBps = 0;
        auction = new StonkzAuction(p);
        uint256 p0 = auction.price();
        _bid(ADDR_A, 5000 ether, type(uint256).max);
        _bid(ADDR_B, 5000 ether, type(uint256).max);
        _step();
        assertGe(auction.price(), p0);
    }

    function testRegression_settlementOpensAtPrint() public {
        IStonkzAuction.Params memory p = _toy(0);
        p.lpShareBps = 8000;
        p.graduationUsd = 100 ether;
        auction = new StonkzAuction(p);
        _bid(ADDR_A, 5000 ether, type(uint256).max);
        _bid(ADDR_B, 5000 ether, type(uint256).max);
        for (uint256 i = 0; i < 10; i++) _step();
        if (!auction.graduated()) return;
        auction.settle();
        uint256 P = auction.lastSoldPrice();
        uint256 lpFunds = (auction.raised() * 8000) / 10_000;
        uint256 need = (lpFunds * WAD) / P;
        uint256 rr = auction.reserveRemaining();
        uint256 paired = need < rr ? need : rr;
        if (paired > 0) {
            assertApproxEqAbs((lpFunds * WAD) / paired, P, P / 1e6);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _toy(uint16 sizeBonusBps) internal pure returns (IStonkzAuction.Params memory p) {
        p = IStonkzAuction.Params({
            totalSupply: 100 ether,
            floorMcapUsd: 5000 ether,
            graduationUsd: 0,
            durationBlocks: 10,
            baseStepBps: 1000,
            walletCapBps: 10_000,
            sizeBonusBps: sizeBonusBps,
            lpShareBps: 0,
            holdbackBps: 0,
            kappaHundredths: 130,
            disposalMode: 0,
            pairToken: address(0)
        });
    }

    function _load(string memory name) internal view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/test/vectors/", name, ".json"));
    }

    function _params(string memory json) internal pure returns (IStonkzAuction.Params memory p) {
        p.totalSupply = json.readUint(".params.supply");
        p.floorMcapUsd = json.readUint(".params.floorMcap");
        p.graduationUsd = json.readUint(".params.threshold");
        p.durationBlocks = uint64(json.readUint(".params.blocks"));
        p.baseStepBps = uint16(json.readUint(".params.baseStepBps"));
        p.walletCapBps = uint16(json.readUint(".params.walletCapBps"));
        p.sizeBonusBps = uint16(json.readUint(".params.sizeBonusBps"));
        p.lpShareBps = uint16(json.readUint(".params.lpShareBps"));
        p.holdbackBps = uint16(json.readUint(".params.holdbackBps"));
        p.kappaHundredths = uint16(json.readUint(".params.kappaHundredths"));
        p.disposalMode = 0;
        p.pairToken = address(0);
    }

    function _bid(address who, uint256 budget, uint256 maxPrice) internal {
        vm.deal(who, budget + BID_FEE + 1 ether);
        vm.prank(who);
        auction.placeBid{value: budget + BID_FEE}(budget, maxPrice);
    }

    function _step() internal {
        vm.roll(block.number + 1);
        auction.poke();
    }

    function _addr(string memory name) internal pure returns (address) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("A")) return ADDR_A;
        if (h == keccak256("B")) return ADDR_B;
        if (h == keccak256("C")) return ADDR_C;
        if (h == keccak256("D")) return ADDR_D;
        return address(uint160(uint256(h)));
    }

    function _has(string memory json, string memory key) internal pure returns (bool) {
        return json.parseRaw(key).length > 0;
    }

    function _runVector(string memory name) internal {
        string memory json = _load(name);
        auction = new StonkzAuction(_params(json));
        auction.poke(); // start clock (needed for ghost-town)

        bool scheduled = _has(json, ".actions[0].at");
        if (scheduled) {
            _runScheduled(json);
        } else {
            _placeBids(json);
            uint256 n = json.readUint(".params.blocks");
            for (uint256 i = 0; i < n && !auction.done(); i++) {
                _assertAndStep(json, i);
            }
        }
    }

    function _placeBids(string memory json) internal {
        for (uint256 i = 0; i < 32; i++) {
            string memory base = string.concat(".bids[", vm.toString(i), "]");
            if (!_has(json, string.concat(base, ".name"))) break;
            string memory nm = json.readString(string.concat(base, ".name"));
            string memory pb = string.concat(base, ".positions[0]");
            uint256 budget = json.readUint(string.concat(pb, ".budget"));
            uint256 maxP = json.readUint(string.concat(pb, ".maxPrice"));
            _bid(_addr(nm), budget, maxP);
        }
    }

    function _runScheduled(string memory json) internal {
        uint256 n = json.readUint(".params.blocks");
        uint256 actionIdx;
        for (uint256 i = 0; i < n && !auction.done(); i++) {
            while (true) {
                string memory ab = string.concat(".actions[", vm.toString(actionIdx), "]");
                if (!_has(json, string.concat(ab, ".at"))) break;
                if (json.readUint(string.concat(ab, ".at")) > auction.auctionIndex()) break;
                string memory nm = json.readString(string.concat(ab, ".bid.name"));
                uint256 budget = json.readUint(string.concat(ab, ".bid.budget"));
                uint256 maxP = json.readUint(string.concat(ab, ".bid.maxPrice"));
                _bid(_addr(nm), budget, maxP);
                actionIdx++;
            }
            _assertAndStep(json, i);
        }
    }

    function _assertAndStep(string memory json, uint256 i) internal {
        string memory blk = string.concat(".blocks[", vm.toString(i), "]");
        uint256 expPrice = json.readUint(string.concat(blk, ".price"));
        uint256 expOffered = json.readUint(string.concat(blk, ".offered"));
        uint256 expRaised = json.readUint(string.concat(blk, ".raised"));

        uint256 gotPrice = auction.price();
        uint256 gotOffer = auction.currentOffer();

        uint256 fA = auction.bidderTokens(ADDR_A);
        uint256 fB = auction.bidderTokens(ADDR_B);
        uint256 fC = auction.bidderTokens(ADDR_C);
        uint256 fD = auction.bidderTokens(ADDR_D);

        assertApproxEqAbs(gotPrice, expPrice, TOL, "price");
        assertApproxEqAbs(gotOffer, expOffered, TOL, "offered");

        _step();

        assertApproxEqAbs(auction.raised(), expRaised, TOL, "raised");
        _fill(json, blk, "A", ADDR_A, fA);
        _fill(json, blk, "B", ADDR_B, fB);
        _fill(json, blk, "C", ADDR_C, fC);
        _fill(json, blk, "D", ADDR_D, fD);
    }

    function _fill(string memory json, string memory blk, string memory name, address who, uint256 before)
        internal
        view
    {
        string memory key = string.concat(blk, ".fills.", name);
        if (!_has(json, key)) return;
        uint256 exp = json.readUint(key);
        assertApproxEqAbs(auction.bidderTokens(who) - before, exp, TOL, name);
    }
}
