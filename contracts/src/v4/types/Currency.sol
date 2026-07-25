// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @dev Minimal Uniswap v4 Currency type (address wrapper). Spec §8 settlement venue.
type Currency is address;

using CurrencyLibrary for Currency global;

library CurrencyLibrary {
    function toAddress(Currency c) internal pure returns (address) {
        return Currency.unwrap(c);
    }

    function fromAddress(address a) internal pure returns (Currency) {
        return Currency.wrap(a);
    }

    function equals(Currency a, Currency b) internal pure returns (bool) {
        return Currency.unwrap(a) == Currency.unwrap(b);
    }

    function lessThan(Currency a, Currency b) internal pure returns (bool) {
        return uint160(Currency.unwrap(a)) < uint160(Currency.unwrap(b));
    }
}
