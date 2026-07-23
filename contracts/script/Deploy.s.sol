// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

// One-command scripted deploy (spec sec 10). The SAME script runs the burner
// dress rehearsal and the fresh production deploy — only the key and cap
// config differ. Anything manual between rehearsal and production is where
// mistakes live.
//
// REQUIREMENTS:
// - all config in code (this file), no interactive steps
// - admin/pauser/fee roles assigned at construction to ADMIN_MULTISIG
// - deployer address ends the run with zero powers (assert it)
// - genesis ($STONKZ4663) only ever initiated on the production deploy
contract Deploy {}
