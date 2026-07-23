// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test, stdJson, console2} from "forge-std/Test.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";

/// @notice Report-only differential scan of all 200 fuzz vectors (no halt).
contract ForensicScanReportTest is Test {
    using stdJson for string;

    uint256 internal constant TOL = 1e18;
    uint256 internal constant BID_FEE = 1e18 / 10;

    address internal constant ADDR_A = address(0xA11);
    address internal constant ADDR_B = address(0xB22);
    address internal constant ADDR_C = address(0xC33);
    address internal constant ADDR_D = address(0xD44);
    address internal constant ADDR_E = address(0xE55);
    address internal constant ADDR_F = address(0xF66);
    address internal constant ADDR_G = address(uint160(0x677));
    address internal constant ADDR_H = address(uint160(0x688));

    StonkzAuction internal auction;
    uint256 internal _t;

    function test_scanAll200_reportOnly() public {
        vm.pauseGasMetering();
        string memory root = string.concat(vm.projectRoot(), "/test/vectors/fuzz/");
        string memory manifest = vm.readFile(string.concat(root, "manifest.json"));
        uint256 count = manifest.readUint(".count");
        string memory csvPath = string.concat(root, "scan-report.csv");
        vm.writeFile(csvPath, "scenario,firstBlock,field,magnitude,tightCap,sizeBonus,multiBid\n");

        uint256 nDiv;
        uint256 nTight;
        uint256 nBonus;
        uint256 nMulti;
        uint256 nDivTight;
        uint256 nDivBonus;
        uint256 nDivMulti;
        uint256 nCtorSkip;

        for (uint256 i = 0; i < count; i++) {
            string memory json = vm.readFile(string.concat(root, "fuzz-", _pad3(i), ".json"));
            (bool tight, bool bonus, bool multi) = _flags(json);
            if (tight) nTight++;
            if (bonus) nBonus++;
            if (multi) nMulti++;

            (int256 blk, string memory field, uint256 mag) = _scanOne(json);
            if (keccak256(bytes(field)) == keccak256("ctor-skip")) {
                nCtorSkip++;
                continue;
            }
            if (blk >= 0) {
                nDiv++;
                if (tight) nDivTight++;
                if (bonus) nDivBonus++;
                if (multi) nDivMulti++;
                vm.writeLine(
                    csvPath,
                    string.concat(
                        vm.toString(i),
                        ",",
                        vm.toString(uint256(blk)),
                        ",",
                        field,
                        ",",
                        vm.toString(mag),
                        ",",
                        tight ? "1" : "0",
                        ",",
                        bonus ? "1" : "0",
                        ",",
                        multi ? "1" : "0"
                    )
                );
            }
        }

        console2.log("SCAN_SUMMARY divergences", nDiv);
        console2.log("SCAN_SUMMARY total", count);
        console2.log("SCAN_SUMMARY nTightCap", nTight);
        console2.log("SCAN_SUMMARY nSizeBonus", nBonus);
        console2.log("SCAN_SUMMARY nMultiBid", nMulti);
        console2.log("SCAN_SUMMARY divAndTight", nDivTight);
        console2.log("SCAN_SUMMARY divAndBonus", nDivBonus);
        console2.log("SCAN_SUMMARY divAndMulti", nDivMulti);
        console2.log("SCAN_SUMMARY ctorSkip", nCtorSkip);

        vm.writeFile(
            string.concat(root, "scan-report-summary.json"),
            string.concat(
                "{\"seed\":4663,\"divergences\":",
                vm.toString(nDiv),
                ",\"total\":",
                vm.toString(count),
                ",\"nTightCap\":",
                vm.toString(nTight),
                ",\"nSizeBonus\":",
                vm.toString(nBonus),
                ",\"nMultiBid\":",
                vm.toString(nMulti),
                ",\"divAndTight\":",
                vm.toString(nDivTight),
                ",\"divAndBonus\":",
                vm.toString(nDivBonus),
                ",\"divAndMulti\":",
                vm.toString(nDivMulti),
                ",\"ctorSkip\":",
                vm.toString(nCtorSkip),
                "}"
            )
        );
    }

    function _flags(string memory json) internal pure returns (bool tight, bool bonus, bool multi) {
        tight = json.readUint(".params.walletCapBps") < 2000;
        bonus = json.readUint(".params.sizeBonusBps") > 0;
        uint256[8] memory counts;
        for (uint256 a = 0; a < 32; a++) {
            string memory ab = string.concat(".actions[", vm.toString(a), "]");
            if (!_has(json, string.concat(ab, ".at"))) break;
            uint256 idx = _nameIdx(json.readString(string.concat(ab, ".bid.name")));
            if (idx < 8) {
                counts[idx]++;
                if (counts[idx] > 1) multi = true;
            }
        }
    }

    function _scanOne(string memory json)
        internal
        returns (int256 firstBlock, string memory field, uint256 magnitude)
    {
        firstBlock = -1;
        IStonkzAuction.Params memory p = _params(json);
        try this.deployAuction(p) returns (StonkzAuction a) {
            auction = a;
        } catch {
            return (-1, "ctor-skip", 0);
        }

        auction.poke();
        uint256 n = json.readUint(".params.blocks");
        uint256 actionIdx;
        _t = block.timestamp;
        for (uint256 b = 0; b < n && !auction.done(); b++) {
            while (true) {
                string memory ab = string.concat(".actions[", vm.toString(actionIdx), "]");
                if (!_has(json, string.concat(ab, ".at"))) break;
                if (json.readUint(string.concat(ab, ".at")) > auction.auctionIndex()) break;
                _place(json, ab);
                actionIdx++;
            }

            string memory blk = string.concat(".blocks[", vm.toString(b), "]");
            if (!_has(json, string.concat(blk, ".price"))) break;

            uint256 expPrice = json.readUint(string.concat(blk, ".price"));
            uint256 expOffered = json.readUint(string.concat(blk, ".offered"));
            if (_delta(auction.price(), expPrice) > TOL) {
                return (int256(b), "price", _delta(auction.price(), expPrice));
            }
            if (_delta(auction.currentOffer(), expOffered) > TOL) {
                return (int256(b), "offered", _delta(auction.currentOffer(), expOffered));
            }

            uint256 fA = auction.bidderTokens(ADDR_A);
            uint256 fB = auction.bidderTokens(ADDR_B);

             _t += 1;
            vm.warp(_t);
            auction.poke();

            uint256 expRaised = json.readUint(string.concat(blk, ".raised"));
            if (_delta(auction.raised(), expRaised) > TOL) {
                return (int256(b), "raised", _delta(auction.raised(), expRaised));
            }
            if (_has(json, string.concat(blk, ".fills.A"))) {
                uint256 exp = json.readUint(string.concat(blk, ".fills.A"));
                uint256 got = auction.bidderTokens(ADDR_A) - fA;
                if (_delta(got, exp) > TOL) return (int256(b), "fill:A", _delta(got, exp));
            }
            if (_has(json, string.concat(blk, ".fills.B"))) {
                uint256 exp = json.readUint(string.concat(blk, ".fills.B"));
                uint256 got = auction.bidderTokens(ADDR_B) - fB;
                if (_delta(got, exp) > TOL) return (int256(b), "fill:B", _delta(got, exp));
            }
        }
        return (-1, "", 0);
    }

    function deployAuction(IStonkzAuction.Params memory p) external returns (StonkzAuction) {
        return new StonkzAuction(p);
    }

    function _place(string memory json, string memory ab) internal {
        string memory nm = json.readString(string.concat(ab, ".bid.name"));
        uint256 budget = json.readUint(string.concat(ab, ".bid.budget"));
        uint256 maxP = json.readUint(string.concat(ab, ".bid.maxPrice"));
        address who = _addr(nm);
        vm.deal(who, budget + BID_FEE + 1 ether);
        vm.prank(who);
        try auction.placeBid{value: budget + BID_FEE}(budget, maxP) {} catch {}
    }

    function _params(string memory json) internal pure returns (IStonkzAuction.Params memory p) {
        p.totalSupply = json.readUint(".params.supply");
        p.floorMcapUsd = json.readUint(".params.floorMcap");
        p.graduationUsd = json.readUint(".params.threshold");
        p.durationBlocks = uint64(json.readUint(".params.blocks"));
        p.epochSeconds = 1;
        p.maxClearsPerSync = 0;
        p.baseStepBps = uint16(json.readUint(".params.baseStepBps"));
        p.walletCapBps = uint16(json.readUint(".params.walletCapBps"));
        p.sizeBonusBps = uint16(json.readUint(".params.sizeBonusBps"));
        p.lpShareBps = uint16(json.readUint(".params.lpShareBps"));
        p.holdbackBps = uint16(json.readUint(".params.holdbackBps"));
        p.kappaHundredths = uint16(json.readUint(".params.kappaHundredths"));
        if (p.kappaHundredths < 100) p.kappaHundredths = 100;
        p.disposalMode = 0;
        p.pairToken = address(0);
    }

    function _addr(string memory name) internal pure returns (address) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("A")) return ADDR_A;
        if (h == keccak256("B")) return ADDR_B;
        if (h == keccak256("C")) return ADDR_C;
        if (h == keccak256("D")) return ADDR_D;
        if (h == keccak256("E")) return ADDR_E;
        if (h == keccak256("F")) return ADDR_F;
        if (h == keccak256("G")) return ADDR_G;
        if (h == keccak256("H")) return ADDR_H;
        return address(uint160(uint256(h)));
    }

    function _nameIdx(string memory name) internal pure returns (uint256) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("A")) return 0;
        if (h == keccak256("B")) return 1;
        if (h == keccak256("C")) return 2;
        if (h == keccak256("D")) return 3;
        if (h == keccak256("E")) return 4;
        if (h == keccak256("F")) return 5;
        if (h == keccak256("G")) return 6;
        if (h == keccak256("H")) return 7;
        return 99;
    }

    function _has(string memory json, string memory key) internal pure returns (bool) {
        return json.parseRaw(key).length > 0;
    }

    function _delta(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _pad3(uint256 i) internal pure returns (string memory) {
        if (i >= 100) {
            return string(abi.encodePacked(_digit(i / 100), _digit((i / 10) % 10), _digit(i % 10)));
        }
        if (i >= 10) {
            return string(abi.encodePacked("0", _digit(i / 10), _digit(i % 10)));
        }
        return string(abi.encodePacked("00", _digit(i)));
    }

    function _digit(uint256 d) internal pure returns (bytes1) {
        return bytes1(uint8(48 + d));
    }
}
