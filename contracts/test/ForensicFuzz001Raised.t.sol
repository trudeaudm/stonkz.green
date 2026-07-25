// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, stdJson} from "forge-std/Test.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";
import {console2} from "forge-std/console2.sol";

contract ForensicFuzz001Raised is Test {
    using stdJson for string;
    uint256 internal constant TOL = 1e18;
    uint256 internal constant BID_FEE = 1e18 / 10;
    uint256 internal _t;

    function test_fuzz001_raised_trace() public {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/test/vectors/fuzz/fuzz-001.json"));
        StonkzAuction lazy = _deploy(json, false);
        StonkzAuction eager = _deploy(json, true);
        lazy.poke();
        eager.poke();
        _t = block.timestamp;
        uint256 n = json.readUint(".params.blocks");
        uint256 actionIdx;
        for (uint256 b = 0; b < n && !lazy.done(); b++) {
            while (true) {
                string memory ab = string.concat(".actions[", vm.toString(actionIdx), "]");
                if (!_has(json, string.concat(ab, ".at"))) break;
                if (json.readUint(string.concat(ab, ".at")) > lazy.auctionIndex()) break;
                _placeBoth(json, ab, lazy, eager);
                actionIdx++;
            }
            string memory blk = string.concat(".blocks[", vm.toString(b), "]");
            uint256 expRaised = json.readUint(string.concat(blk, ".raised"));
            uint256 lr0 = lazy.raised();
            uint256 er0 = eager.raised();
            _t += 1;
            vm.warp(_t);
            lazy.poke();
            eager.poke();
            console2.log("--- after clear ---");
            console2.log("b", b);
            console2.log("expRaised", expRaised);
            console2.log("lazyRaised", lazy.raised());
            console2.log("eagerRaised", eager.raised());
            console2.log("dLazyBlock", lazy.raised() - lr0);
            console2.log("dEagerBlock", eager.raised() - er0);
            console2.log("lazyVsExp", _delta(lazy.raised(), expRaised));
            console2.log("eagerVsExp", _delta(eager.raised(), expRaised));
            console2.log("lazyVsEager", _delta(lazy.raised(), eager.raised()));
            console2.log("lazySold", lazy.sold());
            console2.log("eagerSold", eager.sold());
            if (_delta(lazy.raised(), expRaised) > TOL) {
                console2.log("HALT at block", b);
                break;
            }
        }
    }

    function _deploy(string memory json, bool eagerFills) internal returns (StonkzAuction) {
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

    function _placeBoth(string memory json, string memory ab, StonkzAuction lazy, StonkzAuction eager) internal {
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

    function _has(string memory json, string memory key) internal pure returns (bool) {
        return json.parseRaw(key).length > 0;
    }

    function _delta(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}