// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";

/// @notice Task S2: eager vs lazy with derived weight-dust D-bound.
/// D = Σ_{blocks active} ceil(weight_b/WAD) + P (live positions at compare).
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

    function _run(string memory name) internal {
        // Clear dust map between scenarios (new addresses only accumulate).
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

        _placeBids(json, eager);
        _placeBids(json, lazy);

        uint256 n = json.readUint(".params.blocks");
        for (uint256 i = 0; i < n && !eager.done(); i++) {
            assertEq(lazy.price(), eager.price(), "price");
            assertEq(lazy.sold(), eager.sold(), "sold");
            assertEq(lazy.raised(), eager.raised(), "raised");
            assertEq(lazy.extraSold(), eager.extraSold(), "extraSold");

            _recordWeightDust(eager);

            _t += 1;
            vm.warp(_t);
            eager.poke();
            lazy.poke();
        }
        assertEq(lazy.price(), eager.price(), "price final");
        assertEq(lazy.sold(), eager.sold(), "sold final");
        assertEq(lazy.raised(), eager.raised(), "raised final");
        assertEq(lazy.extraSold(), eager.extraSold(), "extraSold final");

        lazy.materializeAll();

        if (eager.done()) {
            eager.settle();
            lazy.settle();
        }
        assertEq(lazy.tokensAccounted(), lazy.sold(), "lazy conservation");
        assertEq(eager.tokensAccounted(), eager.sold(), "eager conservation");
        assertEq(lazy.sold(), eager.sold(), "sold after settle");

        uint256 nPos = eager.nextPositionId();
        assertEq(lazy.nextPositionId(), nPos);
        for (uint256 id = 1; id <= nPos; id++) {
            (, , , uint256 s1, uint256 t1, , , ,) = eager.positions(id);
            (address who, , , uint256 s2, uint256 t2, , , ,) = lazy.positions(id);

            // P = positions of this address (LR slack); status may be OutBudget post-settle.
            uint256 P;
            for (uint256 j = 1; j <= nPos; j++) {
                (address o,,,,,,,,) = lazy.positions(j);
                if (o == who) P++;
            }
            // Four sequential WAD floors vs eager Σcost: take, mulWad, acc, harvest.
            uint256 D = weightDustSum[who] * 4 + P;
            if (D == 0) D = 1;

            uint256 dt = t1 > t2 ? t1 - t2 : t2 - t1;
            uint256 ds = s1 > s2 ? s1 - s2 : s2 - s1;
            if (dt > D || ds > D) {
                emit log_named_uint("posId", id);
                emit log_named_uint("dt", dt);
                emit log_named_uint("ds", ds);
                emit log_named_uint("D", D);
                emit log_named_uint("dustSum", weightDustSum[who]);
                emit log_named_uint("P", P);
            }
            if (dt > D) {
                emit log_string("STOP: token delta > D");
                emit log_named_uint("eagerTok", t1);
                emit log_named_uint("lazyTok", t2);
                fail();
            }
            if (ds > D) {
                emit log_string("STOP: spent delta > D");
                emit log_named_uint("eagerSpent", s1);
                emit log_named_uint("lazySpent", s2);
                fail();
            }
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

    function _liveCount(StonkzAuction a, address who) internal view returns (uint256 live) {
        uint256 n = a.nextPositionId();
        for (uint256 id = 1; id <= n; id++) {
            (address o,,,,, StonkzAuction.PosStatus st,,,) = a.positions(id);
            if (o == who && st == StonkzAuction.PosStatus.Active) live++;
        }
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
