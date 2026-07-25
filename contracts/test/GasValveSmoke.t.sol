// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";
contract GasValveSmoke is Test {
  uint256 constant FEE = 1e17;
  function test_valve4_three() public {
    StonkzAuction b = new StonkzAuction(IStonkzAuction.Params({
      totalSupply: 1_000_000 ether, floorMcapUsd: 50_000 ether, graduationUsd: 0,
      durationBlocks: 100, epochSeconds: 1, maxClearsPerSync: 4, maxUniqueActives: 0,
      baseStepBps: 500, walletCapBps: 10_000, sizeBonusBps: 0, lpShareBps: 8000,
      holdbackBps: 0, kappaHundredths: 130, disposalMode: 0, pairToken: address(0),
      maxLivePositionsPerAddress: 0, eagerFills: false
    }));
    for (uint256 i = 1; i <= 3; i++) {
      address who = address(uint160(i));
      vm.deal(who, 20 ether);
      vm.prank(who);
      b.placeBid{value: 10 ether + FEE}(10 ether, type(uint80).max);
    }
    uint256 t1 = block.timestamp;
    vm.warp(t1 + 1);
    b.poke();
    uint256 idx = b.auctionIndex();
    vm.warp(t1 + 1 + 8);
    b.poke();
    assertEq(b.auctionIndex(), idx + 4);
  }
}
