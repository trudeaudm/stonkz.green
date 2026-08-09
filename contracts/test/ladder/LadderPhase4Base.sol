// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StonkzLadderAuction} from "../../src/ladder/StonkzLadderAuction.sol";
import {LadderConstants} from "../../src/ladder/LadderConstants.sol";
import {LadderTypes} from "../../src/ladder/LadderTypes.sol";
import {LadderMath} from "../../src/ladder/LadderMath.sol";
import {LadderSettlement} from "../../src/ladder/LadderSettlement.sol";
import {IPoolManager} from "../../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../../src/mock/MockPoolManager.sol";
import {StonkzFeeHook} from "../../src/StonkzFeeHook.sol";
import {CTOGovernor} from "../../src/CTOGovernor.sol";
import {ICTOGovernor} from "../../src/interfaces/IStonkzGovernance.sol";
import {MockVault} from "./MockVault.sol";

/// @dev Shared deploy helpers for Phase 4 adversarial / invariant / gas suites.
abstract contract LadderPhase4Base is Test {
    uint256 internal constant WAD = 1e18;
    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCE0);
    address internal constant STONKZ = address(0x4663);

    MockPoolManager internal pm;
    StonkzFeeHook internal hook;
    MockVault internal mockVault;
    address internal VAULT;

    function setUp() public virtual {
        mockVault = new MockVault();
        VAULT = address(mockVault);
        pm = new MockPoolManager();
        CTOGovernor gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)));
        gov.setRegistry(hook);
    }

    function _tierFloor(LadderTypes.Tier t) internal pure returns (uint256) {
        if (t == LadderTypes.Tier.God) return LadderConstants.GOD_LP_HEALTH_FLOOR;
        if (t == LadderTypes.Tier.H4) return LadderConstants.H4_LP_HEALTH_FLOOR;
        if (t == LadderTypes.Tier.Daily) return LadderConstants.DAILY_LP_HEALTH_FLOOR;
        return LadderConstants.ROAD_LP_HEALTH_FLOOR;
    }

    function _duration(LadderTypes.Tier t) internal pure returns (uint256) {
        if (t == LadderTypes.Tier.God) return LadderConstants.GOD_DURATION;
        if (t == LadderTypes.Tier.H4) return LadderConstants.H4_DURATION;
        if (t == LadderTypes.Tier.Daily) return LadderConstants.DAILY_DURATION;
        return LadderConstants.ROAD_DURATION;
    }

    function _lpShareWad(uint16 carveBps, uint16 cashHbBps) internal pure returns (uint256) {
        return (uint256(10_000 - carveBps - cashHbBps) * WAD) / 10_000;
    }

    struct DeployCfg {
        LadderTypes.Tier tier;
        uint256 floorMcap;
        uint16 holdbackBps;
        uint16 cashHoldbackBps;
        uint16 walletCapBps;
        uint16 maxUniqueActives;
        uint16 sizeBonusBps;
    }

    function _defaultCfg() internal pure returns (DeployCfg memory c) {
        c = DeployCfg({
            tier: LadderTypes.Tier.God,
            floorMcap: 2_500 ether,
            holdbackBps: 0,
            cashHoldbackBps: 500,
            walletCapBps: 500,
            maxUniqueActives: 300,
            sizeBonusBps: 1000
        });
    }

    function _deploy(DeployCfg memory c) internal returns (StonkzLadderAuction auction) {
        uint16 carve = LadderConstants.DEFAULT_CARVE_BPS;
        uint256 supply = 1_000_000_000 ether;
        uint256 auctionSupply = supply - (supply * c.holdbackBps) / 10_000;
        uint256 floor = _tierFloor(c.tier);
        address vault = c.holdbackBps > 0 ? VAULT : address(0);
        auction = new StonkzLadderAuction(
            StonkzLadderAuction.Params({
                supply: supply,
                auctionSupply: auctionSupply,
                floorMcap: c.floorMcap,
                duration: _duration(c.tier),
                lpShareWad: _lpShareWad(carve, c.cashHoldbackBps),
                lpHealthTargetWad: floor,
                carveBps: carve,
                cashHoldbackBps: c.cashHoldbackBps,
                holdbackBps: c.holdbackBps,
                holdbackDelivery: c.holdbackBps > 0
                    ? LadderConstants.HoldbackDelivery.Vault
                    : LadderConstants.HoldbackDelivery.None,
                tier: c.tier,
                sidePoolBps: LadderConstants.SIDE_POOL_BPS,
                walletCapBps: c.walletCapBps,
                sizeBonusBps: c.sizeBonusBps,
                maxUniqueActives: c.maxUniqueActives,
                pairToken: address(0),
                creator: CREATOR,
                treasury: TREASURY,
                vaultRef: vault
            })
        );
        auction.start();
    }

    function _bid(StonkzLadderAuction auction, address w, uint256 size, uint256 maxPrice) internal {
        vm.deal(w, size + 1 ether);
        vm.prank(w);
        auction.placeBid{value: size}(size, maxPrice);
    }

    function _wireSettlement(StonkzLadderAuction auction) internal returns (LadderSettlement s, MockTok tok) {
        s = new LadderSettlement(IPoolManager(address(pm)), hook, address(0));
        s.setStonkzRef(STONKZ);
        auction.setSettlement(s);
        tok = new MockTok();
    }

    function _assertHealthIfGraduated(StonkzLadderAuction auction) internal view {
        if (auction.graduated()) {
            assertGe(auction.lpHealth(), auction.lpHealthTargetWad(), "lpHealth < tierFloor on graduate");
        }
    }

    function _mcapOfPrice(StonkzLadderAuction auction, uint256 price) internal view returns (uint256) {
        return (price * auction.supply()) / WAD;
    }
}

contract MockTok {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}
