// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

// NOTE: This script is DEPRECATED. Governance transfer is now managed through OllaGovernance.
// The timelock is embedded in OllaGovernance, so there is no need to separately transfer
// governance to a TimelockController.
//
// For governance transfers, use OllaGovernance.proposeGovernance() and acceptGovernance()
// through the timelock schedule/execute flow.
