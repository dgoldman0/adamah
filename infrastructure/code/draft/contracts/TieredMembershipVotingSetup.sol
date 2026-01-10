// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.21;

import {PermissionLib} from "@aragon/osx/core/permission/PermissionLib.sol";
import {PluginSetup, IPluginSetup} from "@aragon/osx/framework/plugin/setup/PluginSetup.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {IDAO} from "@aragon/osx/core/dao/IDAO.sol";

import {TieredMembershipVoting} from "./TieredMembershipVoting.sol";
import {TieredProposerCondition} from "./condition/TieredProposerCondition.sol";

/// @title TieredMembershipVotingSetup (Build 1)
/// @notice Installs an ERC1967 (UUPS) proxy instance and configures permissions. :contentReference[oaicite:6]{index=6}
contract TieredMembershipVotingSetup is PluginSetup {
    address private immutable _impl;

    constructor() {
        _impl = address(new TieredMembershipVoting());
    }

    function implementation() external view returns (address) {
        return _impl;
    }

    /// @dev abi.decode(_data) with:
    /// (TieredMembershipVoting.VotingSettings settings,
    ///  uint8 initialTierCount,
    ///  uint256[] initialTierMultipliers,
    ///  address[] initialMembers,
    ///  uint8[] initialMemberTiers)
    function prepareInstallation(
        address dao,
        bytes calldata data
    ) external returns (address plugin, PreparedSetupData memory prepared) {
        (
            TieredMembershipVoting.VotingSettings memory settings,
            uint8 initialTierCount,
            uint256[] memory initialTierMultipliers,
            address[] memory initialMembers,
            uint8[] memory initialMemberTiers
        ) = abi.decode(
            data,
            (TieredMembershipVoting.VotingSettings, uint8, uint256[], address[], uint8[])
        );

        plugin = createERC1967Proxy(
            _impl,
            abi.encodeCall(
                TieredMembershipVoting.initialize,
                (IDAO(dao), settings, initialTierCount, initialTierMultipliers, initialMembers, initialMemberTiers)
            )
        );

        // Condition for proposers: member + min proposer power
        TieredProposerCondition proposerCondition = new TieredProposerCondition(TieredMembershipVoting(plugin));

        // Permissions
        PermissionLib.MultiTargetPermission;

        // 1) Proposers: ANY_ADDR with condition
        permissions[0] = PermissionLib.MultiTargetPermission({
            operation: PermissionLib.Operation.Grant,
            where: plugin,
            who: PermissionLib.ANY_ADDR,
            condition: address(proposerCondition),
            permissionId: TieredMembershipVoting.PROPOSER_PERMISSION_ID()
        });

        // 2) DAO can update voting settings
        permissions[1] = PermissionLib.MultiTargetPermission({
            operation: PermissionLib.Operation.Grant,
            where: plugin,
            who: dao,
            condition: PermissionLib.NO_CONDITION,
            permissionId: TieredMembershipVoting.UPDATE_VOTING_SETTINGS_PERMISSION_ID()
        });

        // 3) DAO can manage tiers/members/multipliers
        permissions[2] = PermissionLib.MultiTargetPermission({
            operation: PermissionLib.Operation.Grant,
            where: plugin,
            who: dao,
            condition: PermissionLib.NO_CONDITION,
            permissionId: TieredMembershipVoting.MANAGE_TIERS_PERMISSION_ID()
        });

        // 4) Plugin can execute actions on the DAO
        permissions[3] = PermissionLib.MultiTargetPermission({
            operation: PermissionLib.Operation.Grant,
            where: dao,
            who: plugin,
            condition: PermissionLib.NO_CONDITION,
            permissionId: DAO(payable(dao)).EXECUTE_PERMISSION_ID()
        });

        // 5) DAO can upgrade plugin proxy (UUPS) :contentReference[oaicite:8]{index=8}
        permissions[4] = PermissionLib.MultiTargetPermission({
            operation: PermissionLib.Operation.Grant,
            where: plugin,
            who: dao,
            condition: PermissionLib.NO_CONDITION,
            permissionId: TieredMembershipVoting(plugin).UPGRADE_PLUGIN_PERMISSION_ID()
        });

        prepared.permissions = permissions;

        // Track helper for uninstall/update payloads
        prepared.helpers = new address;
        prepared.helpers[0] = address(proposerCondition);
    }

    function prepareUninstallation(
        address dao,
        SetupPayload calldata payload
    ) external view returns (PermissionLib.MultiTargetPermission[] memory permissions) {
        address plugin = payload.plugin;

        // helpers[0] is proposerCondition (created during install)
        address proposerCondition = payload.currentHelpers[0];

        permissions = new PermissionLib.MultiTargetPermission;

        permissions[0] = PermissionLib.MultiTargetPermission({
            operation: PermissionLib.Operation.Revoke,
            where: plugin,
            who: PermissionLib.ANY_ADDR,
            condition: proposerCondition,
            permissionId: TieredMembershipVoting.PROPOSER_PERMISSION_ID()
        });

        permissions[1] = PermissionLib.MultiTargetPermission({
            operation: PermissionLib.Operation.Revoke,
            where: plugin,
            who: dao,
            condition: PermissionLib.NO_CONDITION,
            permissionId: TieredMembershipVoting.UPDATE_VOTING_SETTINGS_PERMISSION_ID()
        });

        permissions[2] = PermissionLib.MultiTargetPermission({
            operation: PermissionLib.Operation.Revoke,
            where: plugin,
            who: dao,
            condition: PermissionLib.NO_CONDITION,
            permissionId: TieredMembershipVoting.MANAGE_TIERS_PERMISSION_ID()
        });

        permissions[3] = PermissionLib.MultiTargetPermission({
            operation: PermissionLib.Operation.Revoke,
            where: dao,
            who: plugin,
            condition: PermissionLib.NO_CONDITION,
            permissionId: DAO(payable(dao)).EXECUTE_PERMISSION_ID()
        });

        permissions[4] = PermissionLib.MultiTargetPermission({
            operation: PermissionLib.Operation.Revoke,
            where: plugin,
            who: dao,
            condition: PermissionLib.NO_CONDITION,
            permissionId: TieredMembershipVoting(plugin).UPGRADE_PLUGIN_PERMISSION_ID()
        });
    }
}
