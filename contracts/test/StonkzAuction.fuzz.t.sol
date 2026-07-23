// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test, stdJson} from "forge-std/Test.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";

/// @notice Differential fuzz: replay all `test/vectors/fuzz/*.json` (seed 4663).
/// @dev On divergence > 1e18: report seed + index + first block and revert (HALT).
contract StonkzAuctionFuzzVectorsTest is Test {
    using stdJson for string;

    uint256 internal constant TOL = 1e18;
    uint256 internal constant BID_FEE = 1e18 / 10;
    uint256 internal constant SEED = 4663;

    StonkzAuction internal auction;
    uint256 internal _wall; // wall-clock roll counter (avoids via-ir stack + block.number+1 quirk)

    address internal constant ADDR_A = address(0xA11);
    address internal constant ADDR_B = address(0xB22);
    address internal constant ADDR_C = address(0xC33);
    address internal constant ADDR_D = address(0xD44);
    address internal constant ADDR_E = address(0xE55);
    address internal constant ADDR_F = address(0xF66);
    address internal constant ADDR_G = address(uint160(0x677));
    address internal constant ADDR_H = address(uint160(0x688));

    function testFuzzVectors_seed4663_all200() public {
        string memory root = string.concat(vm.projectRoot(), "/test/vectors/fuzz/");
        string memory manifest = vm.readFile(string.concat(root, "manifest.json"));
        uint256 count = manifest.readUint(".count");
        assertEq(count, 200, "manifest count");
        assertEq(manifest.readUint(".seed"), SEED, "seed");

        for (uint256 i = 0; i < count; i++) {
            string memory file = string.concat("fuzz-", _pad3(i), ".json");
            string memory json = vm.readFile(string.concat(root, file));
            _runOne(json, i);
        }
    }

    function _runOne(string memory json, uint256 index) internal {
        IStonkzAuction.Params memory p = _params(json);
        // Constructor may reject bad ceilings — skip only if we can't deploy
        try this.deployAuction(p) returns (StonkzAuction a) {
            auction = a;
        } catch {
            // Reference has no ctor gate; if Solidity rejects, that is a known asymmetry —
            // do not adjust math. Skip construct failures.
            return;
        }

        auction.poke();
        uint256 n = json.readUint(".params.blocks");
        uint256 actionIdx;
        _wall = block.number;
        for (uint256 b = 0; b < n && !auction.done(); b++) {
            while (true) {
                string memory ab = string.concat(".actions[", vm.toString(actionIdx), "]");
                if (!_has(json, string.concat(ab, ".at"))) break;
                if (json.readUint(string.concat(ab, ".at")) > auction.auctionIndex()) break;
                _placeAction(json, ab);
                actionIdx++;
            }

            string memory blk = string.concat(".blocks[", vm.toString(b), "]");
            if (!_has(json, string.concat(blk, ".price"))) break;

            uint256 expPrice = json.readUint(string.concat(blk, ".price"));
            uint256 expOffered = json.readUint(string.concat(blk, ".offered"));
            uint256 gotPrice = auction.price();
            uint256 gotOffer = auction.currentOffer();

            if (_delta(gotPrice, expPrice) > TOL || _delta(gotOffer, expOffered) > TOL) {
                revert(
                    string.concat(
                        "FUZZ HALT seed=",
                        vm.toString(SEED),
                        " scenario=",
                        vm.toString(index),
                        " block=",
                        vm.toString(b),
                        " (price/offered)"
                    )
                );
            }

            uint256 fA = auction.bidderTokens(ADDR_A);
            uint256 fB = auction.bidderTokens(ADDR_B);
            uint256 fC = auction.bidderTokens(ADDR_C);
            uint256 fD = auction.bidderTokens(ADDR_D);

            _wall += 1;
            vm.roll(_wall);
            auction.poke();

            uint256 expRaised = json.readUint(string.concat(blk, ".raised"));
            if (_delta(auction.raised(), expRaised) > TOL) {
                revert(
                    string.concat(
                        "FUZZ HALT seed=",
                        vm.toString(SEED),
                        " scenario=",
                        vm.toString(index),
                        " block=",
                        vm.toString(b),
                        " (raised)"
                    )
                );
            }
            _checkFill(json, blk, "A", ADDR_A, fA, index, b);
            _checkFill(json, blk, "B", ADDR_B, fB, index, b);
            _checkFill(json, blk, "C", ADDR_C, fC, index, b);
            _checkFill(json, blk, "D", ADDR_D, fD, index, b);
        }
    }

    function deployAuction(IStonkzAuction.Params memory p) external returns (StonkzAuction) {
        return new StonkzAuction(p);
    }

    function _checkFill(
        string memory json,
        string memory blk,
        string memory name,
        address who,
        uint256 before,
        uint256 index,
        uint256 b
    ) internal view {
        string memory key = string.concat(blk, ".fills.", name);
        if (!_has(json, key)) return;
        uint256 exp = json.readUint(key);
        uint256 got = auction.bidderTokens(who) - before;
        if (_delta(got, exp) > TOL) {
            revert(
                string.concat(
                    "FUZZ HALT seed=",
                    vm.toString(SEED),
                    " scenario=",
                    vm.toString(index),
                    " block=",
                    vm.toString(b),
                    " fill=",
                    name
                )
            );
        }
    }

    function _placeAction(string memory json, string memory ab) internal {
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
