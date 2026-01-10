// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.21;

import {PermissionCondition} from "@aragon/osx/core/permission/condition/PermissionCondition.sol";
import {TieredMembershipVoting} from "../TieredMembershipVoting.sol";

/// @notice Conditional permission: grants if caller is a member (at previous block) and meets min proposer power.
/// @dev Used to grant PROPOSER_PERMISSION_ID to ANY_ADDR with a condition. :contentReference[oaicite:5]{index=5}
contract TieredProposerCondition is PermissionCondition {
    TieredMembershipVoting public immutable plugin;

    constructor(TieredMembershipVoting plugin_) {
        plugin = plugin_;
    }

    function isGranted(
        address /*_where*/,
        address who,
        bytes32 /*_permissionId*/,
        bytes calldata /*_data*/
    ) external view override returns (bool) {
        uint256 snapshot = block.number - 1;
        uint256 power = plugin.votingPowerAt(who, snapshot);
        if (power == 0) return false;

        (, , , , , uint256 minProposerPower) = plugin.votingSettings();
        return power >= minProposerPower;
    }
}
