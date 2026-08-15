// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VanityHelpers} from "./VanityHelpers.sol";
import {EthUsdRefHelpers} from "./EthUsdRefHelpers.sol";
import {StonkzExpressFactory} from "../src/StonkzExpressFactory.sol";
import {StonkzLadderFactory} from "../src/ladder/StonkzLadderFactory.sol";
import {StonkzDirectListing} from "../src/StonkzDirectListing.sol";
import {StonkzLadderAuction} from "../src/ladder/StonkzLadderAuction.sol";

/// @title FactoryVanity — test mixin: mine 0x4663 salts then list/file
abstract contract FactoryVanity is Test {
    uint256 internal constant DEFAULT_TEST_ETH_USD_WAD = 1880e18;

    function _ensureEthUsdRef(StonkzExpressFactory factory) internal {
        if (factory.refPoolManager() == address(0)) {
            EthUsdRefHelpers.wireExpressRef(factory, DEFAULT_TEST_ETH_USD_WAD);
        }
    }

    function _list(StonkzExpressFactory factory, StonkzDirectListing.ListingParams memory p)
        internal
        returns (StonkzDirectListing listing)
    {
        _ensureEthUsdRef(factory);
        (bytes32 userSalt,) = VanityHelpers.mineExpress(factory, address(this), p);
        listing = factory.list(p, userSalt);
    }

    function _listAs(StonkzExpressFactory factory, address who, StonkzDirectListing.ListingParams memory p)
        internal
        returns (StonkzDirectListing listing)
    {
        _ensureEthUsdRef(factory);
        (bytes32 userSalt,) = VanityHelpers.mineExpress(factory, who, p);
        vm.prank(who);
        listing = factory.list(p, userSalt);
    }

    function _file(StonkzLadderFactory factory, StonkzLadderAuction.Params memory p)
        internal
        returns (StonkzLadderAuction auction)
    {
        (bytes32 userSalt,) = VanityHelpers.mineLadder(factory, address(this), p);
        auction = factory.file(p, userSalt);
    }

    function _fileAs(StonkzLadderFactory factory, address who, StonkzLadderAuction.Params memory p)
        internal
        returns (StonkzLadderAuction auction)
    {
        (bytes32 userSalt,) = VanityHelpers.mineLadder(factory, who, p);
        vm.prank(who);
        auction = factory.file(p, userSalt);
    }
}
