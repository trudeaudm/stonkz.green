// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test, stdJson} from "forge-std/Test.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";
import {console2} from "forge-std/console2.sol";

contract ForensicFuzz022 is Test {
    using stdJson for string;
    uint256 constant TOL = 1e18;
    uint256 constant BID_FEE = 1e18/10;
    uint256 _t;
    function test_fuzz022_raised() public {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/test/vectors/fuzz/fuzz-022.json"));
        StonkzAuction lazy = _d(json, false);
        StonkzAuction eager = _d(json, true);
        lazy.poke(); eager.poke(); _t = block.timestamp;
        uint256 actionIdx;
        uint256 n = json.readUint(".params.blocks");
        for (uint256 b = 0; b < n && !lazy.done(); b++) {
            while (true) {
                string memory ab = string.concat(".actions[", vm.toString(actionIdx), "]");
                if (json.parseRaw(string.concat(ab, ".at")).length == 0) break;
                if (json.readUint(string.concat(ab, ".at")) > lazy.auctionIndex()) break;
                _bid(json, ab, lazy); _bid(json, ab, eager); actionIdx++;
            }
            string memory blk = string.concat(".blocks[", vm.toString(b), "]");
            uint256 expR = json.readUint(string.concat(blk, ".raised"));
            _t += 1; vm.warp(_t); lazy.poke(); eager.poke();
            console2.log("b", b);
            console2.log("exp", expR);
            console2.log("lazy", lazy.raised());
            console2.log("eager", eager.raised());
            console2.log("lazyVsExp", _delta(lazy.raised(), expR));
            console2.log("eagerVsExp", _delta(eager.raised(), expR));
            console2.log("lazyVsEager", _delta(lazy.raised(), eager.raised()));
            console2.log("lazySold", lazy.sold());
            console2.log("eagerSold", eager.sold());
            if (_delta(lazy.raised(), expR) > TOL) {
                console2.log("HALT");
                console2.log("nActiveL", lazy.activeAddressCount());
                console2.log("nActiveE", eager.activeAddressCount());
                break;
            }
        }
    }
    function _d(string memory json, bool e) internal returns (StonkzAuction) {
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
        p.eagerFills = e;
        return new StonkzAuction(p);
    }
    function _bid(string memory json, string memory ab, StonkzAuction a) internal {
        string memory nm = json.readString(string.concat(ab, ".bid.name"));
        bytes32 h = keccak256(bytes(nm));
        address who = address(uint160(uint256(h)));
        if (h == keccak256("A")) who = address(0xA11);
        if (h == keccak256("B")) who = address(0xB22);
        if (h == keccak256("C")) who = address(0xC33);
        if (h == keccak256("D")) who = address(0xD44);
        if (h == keccak256("E")) who = address(0xE55);
        if (h == keccak256("F")) who = address(0xF66);
        uint256 budget = json.readUint(string.concat(ab, ".bid.budget"));
        uint256 maxP = json.readUint(string.concat(ab, ".bid.maxPrice"));
        vm.deal(who, budget + BID_FEE + 1 ether);
        vm.prank(who);
        try a.placeBid{value: budget + BID_FEE}(budget, maxP) {} catch {}
    }
    function _delta(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}