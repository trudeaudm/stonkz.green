// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, stdJson} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";
import {console2} from "forge-std/console2.sol";

contract ForensicG1SetDiff is Test {
    using stdJson for string;
    uint256 internal constant BID_FEE = 1e18 / 10;
    uint256 internal _t;
    StonkzAuction internal lazy;
    StonkzAuction internal eager;
    string internal json;

    bytes32 internal constant FILLED = keccak256("Filled(address,uint256,uint256,uint256,uint64)");
    bytes32 internal constant ALLIN = keccak256("AllIn(address,uint256,uint64)");
    bytes32 internal constant CAPPED = keccak256("Capped(address,uint64)");
    bytes32 internal constant PRICED = keccak256("PricedOut(address,uint256,uint256,uint64)");

    function test_g1_setdiff_block10() public {
        json = vm.readFile(string.concat(vm.projectRoot(), "/test/vectors/fuzz/fuzz-001.json"));
        lazy = _deploy(false);
        eager = _deploy(true);
        lazy.poke();
        eager.poke();
        _t = block.timestamp;
        uint256 n = json.readUint(".params.blocks");
        uint256 actionIdx;

        for (uint256 b = 0; b < n && !lazy.done(); b++) {
            actionIdx = _placeDue(actionIdx);
            if (b >= 7 && b <= 10) _pre(b);
            _clearOne(b);
            if (b == 10) break;
        }
    }

    function _placeDue(uint256 actionIdx) internal returns (uint256) {
        while (true) {
            string memory ab = string.concat(".actions[", vm.toString(actionIdx), "]");
            if (!_has(string.concat(ab, ".at"))) break;
            if (json.readUint(string.concat(ab, ".at")) > lazy.auctionIndex()) break;
            _placeBoth(ab);
            actionIdx++;
        }
        return actionIdx;
    }

    function _pre(uint256 b) internal view {
        console2.log("======== PRE-CLEAR ========");
        console2.log("b", b);
        _dumpActives("EAGER", eager);
        _dumpActives("LAZY", lazy);
        _dumpPos("E-B", eager, address(0xB22));
        _dumpPos("L-B", lazy, address(0xB22));
        _dumpPos("E-C", eager, address(0xC33));
        _dumpPos("L-C", lazy, address(0xC33));
    }

    function _clearOne(uint256 b) internal {
        uint256 eSold0 = eager.sold();
        uint256 lSold0 = lazy.sold();
        uint256 eRaised0 = eager.raised();
        uint256 lRaised0 = lazy.raised();

        _t += 1;
        vm.warp(_t);

        vm.recordLogs();
        lazy.poke();
        Vm.Log[] memory lazyLogs = vm.getRecordedLogs();

        vm.recordLogs();
        eager.poke();
        Vm.Log[] memory eagerLogs = vm.getRecordedLogs();

        if (b < 7 || b > 10) return;

        console2.log("======== POST-CLEAR ========");
        console2.log("b", b);
        _sumFills("EAGER", eagerLogs, b);
        _sumFills("LAZY", lazyLogs, b);
        _dumpMarks("EAGER", eagerLogs);
        _dumpMarks("LAZY", lazyLogs);
        console2.log("lazy_dSold", lazy.sold() - lSold0);
        console2.log("eager_dSold", eager.sold() - eSold0);
        console2.log("lazy_dRaised", lazy.raised() - lRaised0);
        console2.log("eager_dRaised", eager.raised() - eRaised0);
        uint256 ds = lazy.sold() > eager.sold() ? lazy.sold() - eager.sold() : 0;
        uint256 dr = lazy.raised() > eager.raised() ? lazy.raised() - eager.raised() : 0;
        console2.log("cum_dSold_lazy_minus_eager", ds);
        console2.log("cum_dRaised_lazy_minus_eager", dr);
    }

    function _dumpActives(string memory tag, StonkzAuction a) internal view {
        uint256 n = a.activeAddressCount();
        console2.log(tag);
        console2.log("nActive", n);
        for (uint256 i = 0; i < n; i++) {
            address who = a.activeAddrs(i);
            (uint256 w,,,, uint256 ab, uint256 aspent, uint32 ac,,) = a.bidders(who);
            console2.log("addr", _name(who));
            console2.log("w", w);
            console2.log("headroom", ab > aspent ? ab - aspent : 0);
            console2.log("ac", uint256(ac));
        }
    }

    function _dumpPos(string memory tag, StonkzAuction a, address who) internal view {
        console2.log(tag);
        uint256 n = a.nextPositionId();
        for (uint256 id = 1; id <= n; id++) {
            (address o, uint256 bud,, uint256 spent,, StonkzAuction.PosStatus st,,,) = a.positions(id);
            if (o != who) continue;
            console2.log("id", id);
            console2.log("st", uint256(st));
            console2.log("budLeft", bud > spent ? bud - spent : 0);
        }
    }

    function _sumFills(string memory tag, Vm.Log[] memory logs, uint256 b) internal pure {
        console2.log(tag);
        console2.log("fills");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != FILLED) continue;
            if (logs[i].topics.length < 2) continue;
            address who = address(uint160(uint256(logs[i].topics[1])));
            (uint256 tok, uint256 spent,, uint64 blk) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint64));
            if (uint256(blk) != b) continue;
            console2.log("who", _name(who));
            console2.log("tok", tok);
            console2.log("spent", spent);
        }
    }

    function _dumpMarks(string memory tag, Vm.Log[] memory logs) internal pure {
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
                console2.log("PricedOut", _name(address(uint160(uint256(logs[i].topics[1])))));
                console2.log("pos", uint256(logs[i].topics[2]));
                (, uint64 blk) = abi.decode(logs[i].data, (uint256, uint64));
                console2.log("blk", uint256(blk));
            }
        }
    }

    function _name(address who) internal pure returns (uint256) {
        if (who == address(0xA11)) return 1;
        if (who == address(0xB22)) return 2;
        if (who == address(0xC33)) return 3;
        if (who == address(0xF66)) return 6;
        return uint256(uint160(who));
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
        p.eagerFills = eagerFills;
        return new StonkzAuction(p);
    }

    function _placeBoth(string memory ab) internal {
        address who = _addr(json.readString(string.concat(ab, ".bid.name")));
        uint256 budget = json.readUint(string.concat(ab, ".bid.budget"));
        uint256 maxP = json.readUint(string.concat(ab, ".bid.maxPrice"));
        vm.deal(who, budget + BID_FEE + 1 ether);
        vm.prank(who);
        try lazy.placeBid{value: budget + BID_FEE}(budget, maxP) {} catch {}
        vm.deal(who, budget + BID_FEE + 1 ether);
        vm.prank(who);
        try eager.placeBid{value: budget + BID_FEE}(budget, maxP) {} catch {}
    }

    function _addr(string memory name) internal pure returns (address) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("A")) return address(0xA11);
        if (h == keccak256("B")) return address(0xB22);
        if (h == keccak256("C")) return address(0xC33);
        if (h == keccak256("D")) return address(0xD44);
        if (h == keccak256("E")) return address(0xE55);
        if (h == keccak256("F")) return address(0xF66);
        if (h == keccak256("G")) return address(uint160(0x677));
        if (h == keccak256("H")) return address(uint160(0x688));
        return address(uint160(uint256(h)));
    }

    function _has(string memory key) internal view returns (bool) {
        return json.parseRaw(key).length > 0;
    }
}