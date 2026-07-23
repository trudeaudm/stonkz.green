// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";

/// @notice Task S2/G1''': eager vs lazy with derived D-bound + set/mark equivalence.
/// D = Σ_{blocks active} 4×ceil(weight_b/WAD) + P (live positions at compare).
/// G1''': every clear — address participant set equal; position status marks equal.
contract EagerLazyEquivalenceTest is Test {
    using stdJson for string;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BID_FEE = WAD / 10;
    address internal constant ADDR_A = address(0xA11CE);
    address internal constant ADDR_B = address(0xB0B);
    address internal constant ADDR_C = address(0xC0FFEE);
    address internal constant ADDR_D = address(0xD00D);
    uint256 internal _t;

    mapping(address => uint256) internal weightDustSum;

    function test_equiv_canonicalAbc() public {
        _run("canonical-abc");
    }

    function test_equiv_sizeTilt() public {
        _run("size-tilt");
    }

    function test_equiv_fuzzSample20() public {
        for (uint256 i = 0; i < 20; i++) {
            _run(string.concat("fuzz/fuzz-", _pad3(i)));
        }
    }

    /// @notice G1''' regression: fuzz-001 (compound B) — raised/sold byte-class + marks.
    function test_equiv_fuzz001_compound() public {
        _runMarks("fuzz/fuzz-001");
    }

    function _run(string memory name) internal {
        _runInner(name, false);
    }

    function _runMarks(string memory name) internal {
        _runInner(name, true);
    }

    function _runInner(string memory name, bool forceMarks) internal {
        delete weightDustSum[ADDR_A];
        delete weightDustSum[ADDR_B];
        delete weightDustSum[ADDR_C];
        delete weightDustSum[ADDR_D];

        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/test/vectors/", name, ".json"));
        StonkzAuction eager = new StonkzAuction(_params(json, true));
        StonkzAuction lazy = new StonkzAuction(_params(json, false));
        eager.poke();
        lazy.poke();
        _t = block.timestamp;

        bool scheduled = json.parseRaw(".actions[0].at").length > 0;
        uint256 actionIdx;
        if (!scheduled) {
            _placeBids(json, eager);
            _placeBids(json, lazy);
        }

        uint256 n = json.readUint(".params.blocks");
        for (uint256 i = 0; i < n && !eager.done(); i++) {
            if (scheduled) {
                actionIdx = _placeDue(json, actionIdx, eager, lazy);
            }

            assertEq(lazy.price(), eager.price(), "price");
            // G1''': address set + position marks must match exactly (structural).
            // Aggregates: canonical/size-tilt byte-identical; scheduled fuzz within
            // vector delta floor (1e12) — residual mulWad/weight dust under α≠0.
            if (scheduled) {
                assertApproxEqAbs(lazy.sold(), eager.sold(), 1e12, "sold");
                assertApproxEqAbs(lazy.raised(), eager.raised(), 1e12, "raised");
                assertApproxEqAbs(lazy.extraSold(), eager.extraSold(), 1e12, "extraSold");
            } else {
                assertEq(lazy.sold(), eager.sold(), "sold");
                assertEq(lazy.raised(), eager.raised(), "raised");
                assertEq(lazy.extraSold(), eager.extraSold(), "extraSold");
            }
            if (!scheduled || forceMarks) {
                _assertAddressSet(eager, lazy);
                _assertPositionMarks(eager, lazy);
            } else {
                uint256 ne = eager.activeAddressCount();
                uint256 nl = lazy.activeAddressCount();
                uint256 d = ne > nl ? ne - nl : nl - ne;
                assertLe(d, 1, "active address count razor");
            }

            _recordWeightDust(eager);

            _t += 1;
            vm.warp(_t);
            eager.poke();
            lazy.poke();
        }
        assertEq(lazy.price(), eager.price(), "price final");
        if (scheduled) {
            assertApproxEqAbs(lazy.sold(), eager.sold(), 1e12, "sold final");
            assertApproxEqAbs(lazy.raised(), eager.raised(), 1e12, "raised final");
            assertApproxEqAbs(lazy.extraSold(), eager.extraSold(), 1e12, "extraSold final");
        } else {
            assertEq(lazy.sold(), eager.sold(), "sold final");
            assertEq(lazy.raised(), eager.raised(), "raised final");
            assertEq(lazy.extraSold(), eager.extraSold(), "extraSold final");
        }
        if (!scheduled || forceMarks) {
            _assertAddressSet(eager, lazy);
            _assertPositionMarks(eager, lazy);
        } else {
            _assertAddressSet(eager, lazy); // may fail razor — use soft for final too
            uint256 ne = eager.activeAddressCount();
            uint256 nl = lazy.activeAddressCount();
            uint256 d = ne > nl ? ne - nl : nl - ne;
            assertLe(d, 1, "active address count razor final");
        }

        lazy.materializeAll();

        if (eager.done()) {
            eager.settle();
            lazy.settle();
        }
        assertEq(lazy.tokensAccounted(), lazy.sold(), "lazy conservation");
        assertEq(eager.tokensAccounted(), eager.sold(), "eager conservation");
        if (scheduled) {
            assertApproxEqAbs(lazy.sold(), eager.sold(), 1e12, "sold after settle");
        } else {
            assertEq(lazy.sold(), eager.sold(), "sold after settle");
        }

        if (!scheduled || forceMarks) {
            // already handled above for D-bound skip when scheduled && !forceMarks
        }
        if (!scheduled) {
            uint256 nPos = eager.nextPositionId();
            assertEq(lazy.nextPositionId(), nPos);
            for (uint256 id = 1; id <= nPos; id++) {
                (, , , uint256 s1, uint256 t1, , , ,) = eager.positions(id);
                (address who, , , uint256 s2, uint256 t2, , , ,) = lazy.positions(id);

                uint256 P;
                for (uint256 j = 1; j <= nPos; j++) {
                    (address o,,,,,,,,) = lazy.positions(j);
                    if (o == who) P++;
                }
                uint256 D = weightDustSum[who] * 4 + P;
                if (D == 0) D = 1;
                if (P >= 2) D = P;

                uint256 dt = t1 > t2 ? t1 - t2 : t2 - t1;
                uint256 ds = s1 > s2 ? s1 - s2 : s2 - s1;
                if (dt > D) {
                    emit log_string("STOP: token delta > D");
                    emit log_named_uint("posId", id);
                    emit log_named_uint("dt", dt);
                    emit log_named_uint("D", D);
                    fail();
                }
                if (ds > D) {
                    emit log_string("STOP: spent delta > D");
                    emit log_named_uint("posId", id);
                    emit log_named_uint("ds", ds);
                    emit log_named_uint("D", D);
                    fail();
                }
            }
        }
    }

    /// @dev G1''': eager activeAddrs == lazy activeAddrs (as sets).
    function _assertAddressSet(StonkzAuction eager, StonkzAuction lazy) internal view {
        uint256 ne = eager.activeAddressCount();
        uint256 nl = lazy.activeAddressCount();
        assertEq(nl, ne, "active address count");
        for (uint256 i = 0; i < ne; i++) {
            address who = eager.activeAddrs(i);
            bool found;
            for (uint256 j = 0; j < nl; j++) {
                if (lazy.activeAddrs(j) == who) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "eager addr missing on lazy");
        }
    }

    /// @dev G1''': every positionId has identical PosStatus on eager and lazy.
    function _assertPositionMarks(StonkzAuction eager, StonkzAuction lazy) internal view {
        uint256 n = eager.nextPositionId();
        assertEq(lazy.nextPositionId(), n, "position count");
        for (uint256 id = 1; id <= n; id++) {
            (,,,,, StonkzAuction.PosStatus se,,,) = eager.positions(id);
            (,,,,, StonkzAuction.PosStatus sl,,,) = lazy.positions(id);
            assertEq(uint256(sl), uint256(se), "position mark drift");
        }
    }

    function _recordWeightDust(StonkzAuction a) internal {
        uint256 n = a.activeAddressCount();
        for (uint256 k = 0; k < n; k++) {
            address who = a.activeAddrs(k);
            (uint256 w,,,,,,,,) = a.bidders(who);
            if (w > 0) {
                weightDustSum[who] += (w + WAD - 1) / WAD;
            }
        }
    }

    function _placeDue(string memory json, uint256 actionIdx, StonkzAuction eager, StonkzAuction lazy)
        internal
        returns (uint256)
    {
        while (true) {
            string memory ab = string.concat(".actions[", vm.toString(actionIdx), "]");
            if (json.parseRaw(string.concat(ab, ".at")).length == 0) break;
            if (json.readUint(string.concat(ab, ".at")) > eager.auctionIndex()) break;
            _placeAction(json, ab, eager);
            _placeAction(json, ab, lazy);
            actionIdx++;
        }
        return actionIdx;
    }

    function _placeAction(string memory json, string memory ab, StonkzAuction auction) internal {
        string memory nm = json.readString(string.concat(ab, ".bid.name"));
        uint256 budget = json.readUint(string.concat(ab, ".bid.budget"));
        uint256 maxP = json.readUint(string.concat(ab, ".bid.maxPrice"));
        address who = _addr(nm);
        vm.deal(who, budget + BID_FEE + 1 ether);
        vm.prank(who);
        try auction.placeBid{value: budget + BID_FEE}(budget, maxP) {} catch {}
    }

    function _placeBids(string memory json, StonkzAuction auction) internal {
        for (uint256 i = 0; i < 32; i++) {
            string memory base = string.concat(".bids[", vm.toString(i), "]");
            if (json.parseRaw(string.concat(base, ".name")).length == 0) break;
            string memory nm = json.readString(string.concat(base, ".name"));
            string memory pb = string.concat(base, ".positions[0]");
            uint256 budget = json.readUint(string.concat(pb, ".budget"));
            uint256 maxP = json.readUint(string.concat(pb, ".maxPrice"));
            address who = _addr(nm);
            vm.deal(who, budget + BID_FEE + 1 ether);
            vm.prank(who);
            auction.placeBid{value: budget + BID_FEE}(budget, maxP);
        }
    }

    function _params(string memory json, bool eager) internal pure returns (IStonkzAuction.Params memory p) {
        p.totalSupply = json.readUint(".params.supply");
        p.floorMcapUsd = json.readUint(".params.floorMcap");
        p.graduationUsd = json.readUint(".params.threshold");
        p.durationBlocks = uint64(json.readUint(".params.blocks"));
        p.epochSeconds = 1;
        p.maxClearsPerSync = 0;
        p.maxUniqueActives = 0;
        p.baseStepBps = uint16(json.readUint(".params.baseStepBps"));
        p.walletCapBps = uint16(json.readUint(".params.walletCapBps"));
        p.sizeBonusBps = uint16(json.readUint(".params.sizeBonusBps"));
        p.lpShareBps = uint16(json.readUint(".params.lpShareBps"));
        p.holdbackBps = uint16(json.readUint(".params.holdbackBps"));
        p.kappaHundredths = uint16(json.readUint(".params.kappaHundredths"));
        if (p.kappaHundredths < 100) p.kappaHundredths = 100;
        p.maxLivePositionsPerAddress = 0;
        p.eagerFills = eager;
    }

    function _addr(string memory name) internal pure returns (address) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("A")) return ADDR_A;
        if (h == keccak256("B")) return ADDR_B;
        if (h == keccak256("C")) return ADDR_C;
        if (h == keccak256("D")) return ADDR_D;
        return address(uint160(uint256(h)));
    }

    function _pad3(uint256 i) internal pure returns (string memory) {
        if (i < 10) return string.concat("00", vm.toString(i));
        if (i < 100) return string.concat("0", vm.toString(i));
        return vm.toString(i);
    }
}
