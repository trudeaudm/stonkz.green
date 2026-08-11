// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {FeeLockerV2} from "../src/FeeLockerV2.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {StonkzDirectListing} from "../src/StonkzDirectListing.sol";
import {StonkzExpressFactory} from "../src/StonkzExpressFactory.sol";
import {StonkzLadderFactory} from "../src/ladder/StonkzLadderFactory.sol";
import {StonkzLadderAuction} from "../src/ladder/StonkzLadderAuction.sol";
import {LadderConstants} from "../src/ladder/LadderConstants.sol";
import {LadderTypes} from "../src/ladder/LadderTypes.sol";
import {LadderSettlement} from "../src/ladder/LadderSettlement.sol";

/// @title SwitchDeployGasPhase4 — deploy-path gas after switches (Phase 4 evidence)
contract SwitchDeployGasPhase4 is Test {
    MockPoolManager internal pm;
    BuybackAccumulator internal acc;
    StonkzFeeHook internal hook;
    FeeLockerV2 internal locker;
    CTOGovernor internal gov;
    StonkzExpressFactory internal express;
    StonkzLadderFactory internal ladder;

    address internal constant PAIR = address(0);
    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCEEE);
    address internal constant STONKZ = address(0x4663);

    function setUp() public {
        vm.etch(STONKZ, hex"00");
        pm = new MockPoolManager();
        acc = new BuybackAccumulator(PAIR, STONKZ, address(0));
        gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)));
        gov.setRegistry(hook);
        locker = new FeeLockerV2(IPoolManager(address(pm)), hook);
        express = new StonkzExpressFactory(
            IPoolManager(address(pm)), locker, hook, acc, gov, PAIR, STONKZ
        );
        ladder = new StonkzLadderFactory();
        ladder.setSideTokenRef(STONKZ);
    }

    function test_gas_express_list() public {
        StonkzDirectListing.ListingParams memory p = StonkzDirectListing.ListingParams({
            startMcap: 4000e18,
            totalSupply: 1_000_000 ether,
            creatorReserveBps: 0,
            deliveryMode: 0,
            vestDuration: 0,
            declaredUse: bytes32("ops"),
            creator: CREATOR,
            name: "Stonk",
            symbol: "STK",
            createSidePool: true,
            sidePoolBps: 500,
            liquidityLocked: true,
            refPriceWad: 0
        });
        uint256 g = gasleft();
        express.list(p, bytes32(uint256(1)));
        emit log_named_uint("gas_express_list", g - gasleft());
    }

    function test_gas_ladder_file() public {
        LadderSettlement s = new LadderSettlement(IPoolManager(address(pm)), hook, PAIR);
        StonkzLadderAuction.Params memory p = StonkzLadderAuction.Params({
            supply: 1_000_000 ether,
            auctionSupply: 1_000_000 ether,
            floorMcap: 10_000 ether,
            duration: LadderConstants.GOD_DURATION,
            lpShareWad: 0.9e18,
            lpHealthTargetWad: 0.25e18,
            carveBps: type(uint16).max,
            cashHoldbackBps: 0,
            holdbackBps: 0,
            holdbackDelivery: LadderConstants.HoldbackDelivery.None,
            tier: LadderTypes.Tier.God,
            createSidePool: true,
            sidePoolBps: 500,
            refPriceWad: 0,
            walletCapBps: 500,
            sizeBonusBps: 1000,
            maxUniqueActives: 64,
            pairToken: PAIR,
            creator: CREATOR,
            treasury: TREASURY,
            vaultRef: address(0),
            settlement: address(s)
        });
        uint256 g = gasleft();
        ladder.file(p);
        emit log_named_uint("gas_ladder_file", g - gasleft());
    }
}
