// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, stdJson} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IStonkzAuction} from "../../IStonkzAuction.sol";
import {StonkzAuction} from "../../StonkzAuction.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Forensic harness from the H1 ghost-active investigation (fuzz-022
///         clear-loop set-diff on b2/b3). Part of a pushed STOP arc; retained
///         under test/forensics/ for history — not a regression lock.
/// @dev H1 ghost-active set-diff: fuzz-022 clears b2 and b3.
contract ForensicH1Ghost is Test {
    using stdJson for string;
    uint256 internal constant BID_FEE = 1e18 / 10;
    uint256 internal _t;
    StonkzAuction internal lazy;
    StonkzAuction internal eager;
    string internal json;

    bytes32 internal constant ALLIN = keccak256("AllIn(address,uint256,uint64)");
    bytes32 internal constant CAPPED = keccak256("Capped(address,uint64)");
    bytes32 internal constant PRICED = keccak256("PricedOut(address,uint256,uint64)");
    bytes32 internal constant FILLED = keccak256("Filled(address,uint256,uint256,uint256,uint64)");
    bytes32 internal constant STEPPED = keccak256("PriceStepped(uint256,uint256,uint64)");

    function test_h1_ghost_b2_b3() public {
        json = vm.readFile(string.concat(vm.projectRoot(), "/test/vectors/fuzz/fuzz-022.json"));
        lazy = _deploy(false);
        eager = _deploy(true);
        lazy.poke();
        eager.poke();
        _t = block.timestamp;
        uint256 actionIdx;
        uint256 n = json.readUint(".params.blocks");

        for (uint256 b = 0; b < n && !lazy.done(); b++) {
            actionIdx = _placeDue(actionIdx);

            if (b >= 1 && b <= 3) {
                console2.log("======== PRE-CLEAR ========");
                console2.log("b", b);
                console2.log("lazy.price", lazy.price());
                console2.log("eager.price", eager.price());
                console2.log("priceEqual", lazy.price() == eager.price() ? 1 : 0);
                _dumpBook("LAZY", lazy);
                _dumpBook("EAGER", eager);
            }

            uint256 lp0 = lazy.price();
            uint256 ep0 = eager.price();

            _t += 1;
            vm.warp(_t);

            vm.recordLogs();
            lazy.poke();
            Vm.Log[] memory lLogs = vm.getRecordedLogs();

            vm.recordLogs();
            eager.poke();
            Vm.Log[] memory eLogs = vm.getRecordedLogs();

            if (b >= 1 && b <= 3) {
                console2.log("======== POST-CLEAR ========");
                console2.log("b", b);
                console2.log("lazy.price_after", lazy.price());
                console2.log("eager.price_after", eager.price());
                console2.log("lazy_price_stepped", lazy.price() != lp0 ? 1 : 0);
                console2.log("eager_price_stepped", eager.price() != ep0 ? 1 : 0);
                _dumpMarks("LAZY", lLogs, b);
                _dumpMarks("EAGER", eLogs, b);
                _dumpFills("LAZY", lLogs, b);
                _dumpFills("EAGER", eLogs, b);
                console2.log("lazy_dSold", lazy.sold());
                console2.log("eager_dSold_cum", eager.sold());
                console2.log("nActiveL", lazy.activeAddressCount());
                console2.log("nActiveE", eager.activeAddressCount());
                _dumpBook("LAZY_post", lazy);
                _dumpBook("EAGER_post", eager);

                // Hypothesis (b) probe: would A's pos survive under floor vs stepped?
                uint256 floorPx = lazy.floorPrice();
                console2.log("floorPrice", floorPx);
            }

            if (b == 3) break;
        }
    }

    function _dumpBook(string memory tag, StonkzAuction a) internal view {
        console2.log(tag);
        console2.log("nActive", a.activeAddressCount());
        console2.log("price", a.price());
        uint256 n = a.nextPositionId();
        for (uint256 id = 1; id <= n; id++) {
            (uint256 bud, uint256 maxP, uint256 spent,, uint256 tok, address o, StonkzAuction.PosStatus st,) =
                a.positions(id);
            if (o == address(0)) continue;
            console2.log("pos", id);
            console2.log("owner", _name(o));
            console2.log("st", uint256(st));
            console2.log("maxP", maxP);
            console2.log("maxP_ge_price", maxP >= a.price() ? 1 : 0);
            console2.log("budLeft", bud > spent ? bud - spent : 0);
            console2.log("tok", tok);
        }
        uint256 na = a.activeAddressCount();
        for (uint256 i = 0; i < na; i++) {
            address who = a.activeAddrs(i);
            (uint256 w, uint256 ab, uint256 aspent, uint16 ac,,,,) = a.bidders(who);
            console2.log("activeWho", _name(who));
            console2.log("w", w);
            console2.log("headroom", ab > aspent ? ab - aspent : 0);
            console2.log("ac", uint256(ac));
            // dust?

            console2.log("dustish", ab <= aspent + 1e9 ? 1 : 0);
        }
    }

    function _dumpMarks(string memory tag, Vm.Log[] memory logs, uint256 b) internal pure {
        console2.log(tag);
        console2.log("marks");
        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 t0 = logs[i].topics[0];
            if (t0 == ALLIN) {
                console2.log("AllIn", _name(address(uint160(uint256(logs[i].topics[1])))));
                console2.log("pos", uint256(logs[i].topics[2]));
                console2.log("blk", uint256(abi.decode(logs[i].data, (uint64))));
            } else if (t0 == CAPPED) {
                console2.log("Capped", _name(address(uint160(uint256(logs[i].topics[1])))));
                console2.log("blk", uint256(abi.decode(logs[i].data, (uint64))));
            } else if (t0 == PRICED) {
                // PricedOut(address indexed, uint256 indexed, uint256, uint64)
                console2.log("PricedOut", _name(address(uint160(uint256(logs[i].topics[1])))));
                console2.log("pos", uint256(logs[i].topics[2]));
                (, uint64 blk) = abi.decode(logs[i].data, (uint256, uint64));
                console2.log("blk", uint256(blk));
            } else if (t0 == STEPPED) {
                (uint256 newP, uint256 bps, uint64 blk) = abi.decode(logs[i].data, (uint256, uint256, uint64));
                console2.log("PriceStepped", newP);
                console2.log("bps", bps);
                console2.log("blk", uint256(blk));
            }
        }
        // silence unused
        b;
    }

    function _dumpFills(string memory tag, Vm.Log[] memory logs, uint256 b) internal pure {
        console2.log(tag);
        console2.log("fills");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != FILLED) continue;
            address who = address(uint160(uint256(logs[i].topics[1])));
            (uint256 tok, uint256 spent, uint256 px, uint64 blk) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint64));
            if (uint256(blk) != b) continue;
            console2.log("who", _name(who));
            console2.log("tok", tok);
            console2.log("spent", spent);
            console2.log("fillPx", px);
        }
    }

    function _name(address who) internal pure returns (uint256) {
        if (who == address(0xA11)) return 1;
        if (who == address(0xB22)) return 2;
        return uint256(uint160(who));
    }

    function _placeDue(uint256 actionIdx) internal returns (uint256) {
        while (true) {
            string memory ab = string.concat(".actions[", vm.toString(actionIdx), "]");
            if (json.parseRaw(string.concat(ab, ".at")).length == 0) break;
            if (json.readUint(string.concat(ab, ".at")) > lazy.auctionIndex()) break;
            _bid(ab);
            actionIdx++;
        }
        return actionIdx;
    }

    function _bid(string memory ab) internal {
        string memory nm = json.readString(string.concat(ab, ".bid.name"));
        bytes32 h = keccak256(bytes(nm));
        address who = address(0xA11);
        if (h == keccak256("B")) who = address(0xB22);
        uint256 budget = json.readUint(string.concat(ab, ".bid.budget"));
        uint256 maxP = json.readUint(string.concat(ab, ".bid.maxPrice"));
        vm.deal(who, budget + BID_FEE + 1 ether);
        vm.prank(who);
        try lazy.placeBid{value: budget + BID_FEE}(budget, maxP) {} catch {}
        vm.deal(who, budget + BID_FEE + 1 ether);
        vm.prank(who);
        try eager.placeBid{value: budget + BID_FEE}(budget, maxP) {} catch {}
    }

    function _deploy(bool eagerFills) internal returns (StonkzAuction) {
        IStonkzAuction.Params memory p;
        p.totalSupply = json.readUint(".params.supply");
        p.floorMcapUsd = json.readUint(".params.floorMcap");
        p.graduationUsd = json.readUint(".params.threshold");
        p.durationBlocks = uint64(json.readUint(".params.blocks"));
        p.epochSeconds = 1;
        p.baseStepBps = uint16(json.readUint(".params.baseStepBps"));
        p.walletCapBps = uint16(json.readUint(".params.walletCapBps"));
        p.sizeBonusBps = uint16(json.readUint(".params.sizeBonusBps"));
        p.lpShareBps = uint16(json.readUint(".params.lpShareBps"));
        p.holdbackBps = uint16(json.readUint(".params.holdbackBps"));
        p.kappaHundredths = uint16(json.readUint(".params.kappaHundredths"));
        if (p.kappaHundredths < 100) p.kappaHundredths = 100;
        p.eagerFills = eagerFills;
        return new StonkzAuction(p);
    }
}
