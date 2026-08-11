// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BuybackAccumulator, IBuyExecutor} from "../src/BuybackAccumulator.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {PoolKey} from "../src/v4/types/PoolKey.sol";
import {Currency} from "../src/v4/types/Currency.sol";
import {TickMath} from "../src/v4/TickMath.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

contract MockSideERC20 is ERC20 {
    string private _n;
    string private _s;

    constructor() {
        _n = "SIDE";
        _s = "SIDE";
    }

    function name() public view override returns (string memory) {
        return _n;
    }

    function symbol() public view override returns (string memory) {
        return _s;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @dev 1:1 pair→side executor for unit tests (pre-funded with side tokens).
contract MockBuyExecutor is IBuyExecutor {
    MockSideERC20 public immutable side;
    uint256 public outWad = 1e18; // side per pair, WAD
    bool public hostile; // return less than minOut

    constructor(MockSideERC20 side_) {
        side = side_;
    }

    function setOutWad(uint256 w) external {
        outWad = w;
    }

    function setHostile(bool h) external {
        hostile = h;
    }

    function buyExactIn(uint256 amountIn, uint256 minAmountOut) external payable returns (uint256 amountOut) {
        amountOut = (amountIn * outWad) / 1e18;
        if (hostile) amountOut = minAmountOut > 0 ? minAmountOut - 1 : 0;
        side.transfer(msg.sender, amountOut);
    }

    receive() external payable {}
}

/// @title BuybackAccumulator — Phase 2 v2 (manual DCA, keeper bounds, burn)
contract BuybackAccumulatorTest is Test {
    MockPoolManager internal pm;
    MockSideERC20 internal side;
    MockBuyExecutor internal exec;
    BuybackAccumulator internal acc;

    address internal constant DEAD = address(0x000000000000000000000000000000000000dEaD);
    address internal KEEPER;
    address internal constant STRANGER = address(0xB0B);

    function setUp() public {
        KEEPER = makeAddr("keeper");
        pm = new MockPoolManager();
        side = new MockSideERC20();
        exec = new MockBuyExecutor(side);
        acc = new BuybackAccumulator(address(0), address(side), address(0));
        acc.setPoolManager(address(pm));
        acc.setExecutor(address(exec));
        acc.setKeeper(KEEPER);

        // Pair/side pool at spot = 1 pair per side (sqrtPrice = 2^96).
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(side)),
            fee: 0,
            tickSpacing: 60,
            hooks: address(0)
        });
        // Ensure currency order: address(0) < side.
        require(address(0) < address(side), "order");
        pm.initialize(key, uint160(1) << 96);
        acc.setBuyPoolKey(key);

        side.mint(address(exec), 1_000_000 ether);
        vm.deal(address(this), 10_000 ether);
    }

    function test_fund_and_crank_burnsToDead() public {
        acc.fundETH{value: 100 ether}();
        assertEq(acc.pairBalance(), 100 ether);

        vm.prank(KEEPER);
        (uint256 inAmt, uint256 outAmt, uint256 burned) = acc.crank(200); // 2%
        assertEq(inAmt, 2 ether);
        assertEq(outAmt, 2 ether);
        assertEq(burned, 2 ether);
        assertEq(acc.pairBalance(), 98 ether);
        assertEq(acc.totalBurned(), 2 ether);
        assertEq(side.balanceOf(DEAD), 2 ether);
    }

    function test_crank_onlyKeeperOrOwner() public {
        acc.fundETH{value: 10 ether}();
        vm.prank(STRANGER);
        vm.expectRevert(BuybackAccumulator.NotKeeperOrOwner.selector);
        acc.crank(100);
    }

    function test_crank_pctBand_and_interval() public {
        acc.fundETH{value: 1000 ether}();
        vm.expectRevert(abi.encodeWithSelector(BuybackAccumulator.PctOutOfBand.selector, uint16(50), uint16(100), uint16(300)));
        acc.crank(50);

        vm.prank(KEEPER);
        acc.crank(300); // 3% of 1000 = 30

        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(BuybackAccumulator.CrankTooSoon.selector, acc.lastCrankTime() + 1 hours));
        acc.crank(100);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(KEEPER);
        (uint256 inAmt,,) = acc.crank(100);
        // remaining 970; 1% = 9.7
        assertEq(inAmt, 9.7 ether);
    }

    function test_hostileKeeper_drainBoundedByMaxPct() public {
        acc.fundETH{value: 100 ether}();
        uint256 start = 100 ether;
        // Hostile keeper cranks max every interval for 10 rounds.
        for (uint256 i; i < 10; i++) {
            vm.prank(KEEPER);
            acc.crank(acc.maxPctBps());
            vm.warp(block.timestamp + acc.minCrankInterval());
        }
        // After 10 × 3%: remaining = 100 * (0.97^10) ≈ 73.74
        assertGt(acc.pairBalance(), 70 ether);
        assertLt(acc.totalPairSpent(), start);
        // Max extractable in one interval = maxPct of remaining at that time ≤ maxPct of start
        assertLe(acc.totalPairSpent(), start - (start * (10_000 - uint256(acc.maxPctBps()) * 10) / 10_000));
    }

    function testFuzz_hostileKeeper_bounded(uint8 rounds, uint16 pct) public {
        rounds = uint8(bound(rounds, 1, 24));
        pct = uint16(bound(pct, acc.minPctBps(), acc.maxPctBps()));
        acc.fundETH{value: 1000 ether}();
        uint256 bal = 1000 ether;
        uint256 spent;
        for (uint256 i; i < rounds; i++) {
            uint256 expectIn = (bal * pct) / 10_000;
            vm.prank(KEEPER);
            (uint256 inAmt,,) = acc.crank(pct);
            assertEq(inAmt, expectIn);
            assertLe(inAmt, (bal * acc.maxPctBps()) / 10_000);
            spent += inAmt;
            bal -= inAmt;
            vm.warp(block.timestamp + acc.minCrankInterval());
        }
        assertEq(acc.pairBalance(), bal);
        assertEq(acc.totalPairSpent(), spent);
    }

    function test_slippage_revertsWhenHostileExecutor() public {
        acc.fundETH{value: 100 ether}();
        exec.setHostile(true);
        vm.prank(KEEPER);
        vm.expectRevert();
        acc.crank(100);
    }

    function test_bandHardBounds() public {
        vm.expectRevert(BuybackAccumulator.BandOutOfHardBounds.selector);
        acc.setCrankBand(0, 100);
        vm.expectRevert(BuybackAccumulator.BandOutOfHardBounds.selector);
        acc.setCrankBand(100, 2001);
        acc.setCrankBand(1, 2000);
    }

    function test_parkSurface_gone() public {
        // Compile-time absence asserted by no park/strategy selectors in ABI — runtime probe:
        (bool ok,) = address(acc).call(abi.encodeWithSignature("setStrategy(address)", address(this)));
        assertFalse(ok);
        (ok,) = address(acc).call(abi.encodeWithSignature("parkSidePoolTokens(uint256)", uint256(1)));
        assertFalse(ok);
        (ok,) = address(acc).call(abi.encodeWithSignature("releaseSidePoolTokens(address)", address(this)));
        assertFalse(ok);
        (ok,) = address(acc).call(abi.encodeWithSignature("crankBuyAndBurn()"));
        assertFalse(ok);
    }

    receive() external payable {}
}
