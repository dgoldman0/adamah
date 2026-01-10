// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.21;

import {PluginUUPSUpgradeable, IDAO} from "@aragon/osx/core/plugin/PluginUUPSUpgradeable.sol";
import {IMembership} from "@aragon/osx/core/plugin/membership/IMembership.sol";
import {IProposal} from "@aragon/osx/core/plugin/proposal/IProposal.sol";

import {CheckpointsUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/CheckpointsUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Tiered Membership Voting (OSx UUPS Plugin)
/// @notice Membership-based majority voting where voting power is determined by a member's tier multiplier.
///         All membership/tier/multiplier changes are permissioned to the DAO, so they happen via governance execution.
contract TieredMembershipVoting is PluginUUPSUpgradeable, IMembership, IProposal, ReentrancyGuardUpgradeable {
    using CheckpointsUpgradeable for CheckpointsUpgradeable.History;

    // ========= Constants =========

    uint8 public constant MAX_TIERS = 5;
    uint32 public constant RATIO_BASE = 1_000_000; // OSx-style ratio base (ppm-ish).

    bytes32 public constant PROPOSER_PERMISSION_ID = keccak256("PROPOSER_PERMISSION");
    bytes32 public constant UPDATE_VOTING_SETTINGS_PERMISSION_ID = keccak256("UPDATE_VOTING_SETTINGS_PERMISSION");
    bytes32 public constant MANAGE_TIERS_PERMISSION_ID = keccak256("MANAGE_TIERS_PERMISSION");

    // ========= Errors =========

    error InvalidTierCount(uint8 tierCount);
    error InvalidTier(uint8 tier);
    error InvalidMultiplier(uint256 multiplier);
    error InvalidMember(address member);
    error InvalidBatchLengths();
    error NotAMember(address account);
    error ProposalDoesNotExist(uint256 proposalId);
    error ProposalNotOpen(uint256 proposalId);
    error VoteNotAllowed(uint256 proposalId);
    error AlreadyVoted(uint256 proposalId, address voter);
    error NoVotingPower(address voter);
    error InvalidDates(uint64 startDate, uint64 endDate);
    error DurationOutOfBounds(uint64 duration);
    error MinProposerPowerNotMet(address proposer, uint256 power, uint256 required);
    error ProposalNotExecutable(uint256 proposalId);
    error AlreadyExecuted(uint256 proposalId);

    // ========= Enums / Structs =========

    enum VotingMode {
        Standard,        // 0: no vote replacement, no early execution
        EarlyExecution,  // 1: allow execute once mathematically un-defeatable
        VoteReplacement  // 2: allow changing votes until endDate
    }

    enum VoteOption {
        None,    // 0
        Abstain, // 1
        Yes,     // 2
        No       // 3
    }

    struct VotingSettings {
        VotingMode votingMode;
        uint32 supportThreshold;     // Yes / (Yes + No)  in RATIO_BASE
        uint32 minParticipation;     // (Yes+No+Abstain) / totalPower in RATIO_BASE
        uint64 minDuration;          // seconds
        uint64 maxDuration;          // seconds
        uint256 minProposerPower;    // absolute voting power (tier multiplier)
    }

    struct ProposalCore {
        uint64 startDate;
        uint64 endDate;
        uint64 snapshotBlock; // block.number - 1
        uint256 allowFailureMap;
        bool executed;
    }

    struct Tally {
        uint256 abstain;
        uint256 yes;
        uint256 no;
    }

    // ========= Storage =========

    VotingSettings private _settings;

    // Tier count and multipliers are checkpointed
    CheckpointsUpgradeable.History private _tierCountHistory; // stores tierCount
    mapping(uint8 => CheckpointsUpgradeable.History) private _tierMultiplierHistory; // tier => multiplier checkpointed
    mapping(uint8 => CheckpointsUpgradeable.History) private _tierMemberCountHistory; // tier => member count checkpointed

    // Member tier is checkpointed: tier=0 means not a member
    mapping(address => CheckpointsUpgradeable.History) private _memberTierHistory;

    // Proposal storage
    uint256 private _proposalCount;
    mapping(uint256 => ProposalCore) private _proposals;
    mapping(uint256 => Tally) private _tallies;
    mapping(uint256 => bytes) private _proposalMetadata;
    mapping(uint256 => IDAO.Action[]) private _proposalActions;

    // voter state: choice + fixed power used for this proposal
    mapping(uint256 => mapping(address => VoteOption)) private _voterChoice;
    mapping(uint256 => mapping(address => uint256)) private _voterPower;

    // ========= Events =========

    event VotingSettingsUpdated(VotingSettings settings);

    event TierCountUpdated(uint8 tierCount);
    event TierMultiplierUpdated(uint8 indexed tier, uint256 multiplier);

    event MemberTierUpdated(address indexed member, uint8 previousTier, uint8 newTier);

    event VoteCast(uint256 indexed proposalId, address indexed voter, VoteOption choice, uint256 votingPower);

    // ========= Init =========

    /// @notice Initializes build 1 (fresh install).
    function initialize(
        IDAO dao_,
        VotingSettings calldata settings_,
        uint8 initialTierCount,
        uint256[] calldata initialTierMultipliers, // optional; if empty -> default doubling
        address[] calldata initialMembers,          // optional
        uint8[] calldata initialMemberTiers         // optional (parallel to initialMembers), default tier=1 if empty
    ) external initializer {
        __PluginUUPSUpgradeable_init(dao_);
        __ReentrancyGuard_init();

        _setVotingSettings(settings_);

        _initTiers(initialTierCount, initialTierMultipliers);
        _initMembers(initialMembers, initialMemberTiers);

        emit MembershipContractAnnounced(address(this));
    }

    // ========= IMembership =========

    function isMember(address account) external view override returns (bool) {
        return _currentTier(account) != 0;
    }

    // ========= IProposal =========

    function proposalCount() external view override returns (uint256) {
        return _proposalCount;
    }

    // ========= Settings =========

    function votingSettings() external view returns (VotingSettings memory) {
        return _settings;
    }

    function updateVotingSettings(VotingSettings calldata newSettings)
        external
        auth(UPDATE_VOTING_SETTINGS_PERMISSION_ID)
    {
        _setVotingSettings(newSettings);
        emit VotingSettingsUpdated(newSettings);
    }

    // ========= Tier config (DAO-executed via governance) =========

    function tierCount() public view returns (uint8) {
        return uint8(_tierCountHistory.latest());
    }

    function tierCountAtBlock(uint256 blockNumber) public view returns (uint8) {
        return uint8(_getAtBlockOrLatest(_tierCountHistory, blockNumber));
    }

    function tierMultiplier(uint8 tier) public view returns (uint256) {
        _requireTierExists(tier);
        return _tierMultiplierHistory[tier].latest();
    }

    function tierMultiplierAtBlock(uint8 tier, uint256 blockNumber) public view returns (uint256) {
        _requireTierExists(tier);
        return _getAtBlockOrLatest(_tierMultiplierHistory[tier], blockNumber);
    }

    function tierMemberCount(uint8 tier) public view returns (uint256) {
        _requireTierExists(tier);
        return _tierMemberCountHistory[tier].latest();
    }

    function tierMemberCountAtBlock(uint8 tier, uint256 blockNumber) public view returns (uint256) {
        _requireTierExists(tier);
        return _getAtBlockOrLatest(_tierMemberCountHistory[tier], blockNumber);
    }

    /// @notice Adds a new tier (up to MAX_TIERS). If multiplier=0, defaults to previousTierMultiplier*2.
    function addTier(uint256 multiplier)
        external
        auth(MANAGE_TIERS_PERMISSION_ID)
    {
        uint8 current = tierCount();
        if (current == 0 || current > MAX_TIERS) revert InvalidTierCount(current);
        if (current >= MAX_TIERS) revert InvalidTierCount(current);

        uint8 newTier = current + 1;

        uint256 newMultiplier = multiplier;
        if (newMultiplier == 0) {
            uint256 prev = _tierMultiplierHistory[current].latest();
            newMultiplier = prev * 2;
        }
        if (newMultiplier == 0) revert InvalidMultiplier(newMultiplier);

        _tierCountHistory.push(newTier);
        _tierMultiplierHistory[newTier].push(newMultiplier);
        _tierMemberCountHistory[newTier].push(0);

        emit TierCountUpdated(newTier);
        emit TierMultiplierUpdated(newTier, newMultiplier);
    }

    function setTierMultiplier(uint8 tier, uint256 multiplier)
        external
        auth(MANAGE_TIERS_PERMISSION_ID)
    {
        _requireTierExists(tier);
        if (multiplier == 0) revert InvalidMultiplier(multiplier);
        _tierMultiplierHistory[tier].push(multiplier);
        emit TierMultiplierUpdated(tier, multiplier);
    }

    function setTierMultipliers(uint8[] calldata tiers, uint256[] calldata multipliers)
        external
        auth(MANAGE_TIERS_PERMISSION_ID)
    {
        if (tiers.length != multipliers.length) revert InvalidBatchLengths();
        for (uint256 i = 0; i < tiers.length; i++) {
            uint8 t = tiers[i];
            uint256 m = multipliers[i];
            _requireTierExists(t);
            if (m == 0) revert InvalidMultiplier(m);
            _tierMultiplierHistory[t].push(m);
            emit TierMultiplierUpdated(t, m);
        }
    }

    // ========= Membership + tier assignment (DAO-executed via governance) =========

    function memberTier(address member) public view returns (uint8) {
        return _currentTier(member);
    }

    function memberTierAtBlock(address member, uint256 blockNumber) public view returns (uint8) {
        return uint8(_getAtBlockOrLatest(_memberTierHistory[member], blockNumber));
    }

    /// @notice Set an individual member tier. newTier=0 removes membership.
    function setMemberTier(address member, uint8 newTier)
        external
        auth(MANAGE_TIERS_PERMISSION_ID)
    {
        _setMemberTier(member, newTier);
    }

    function batchSetMemberTier(address[] calldata members, uint8[] calldata newTiers)
        external
        auth(MANAGE_TIERS_PERMISSION_ID)
    {
        if (members.length != newTiers.length) revert InvalidBatchLengths();
        for (uint256 i = 0; i < members.length; i++) {
            _setMemberTier(members[i], newTiers[i]);
        }
    }

    function promote(address member) external auth(MANAGE_TIERS_PERMISSION_ID) {
        uint8 cur = _currentTier(member);
        if (cur == 0) revert NotAMember(member);
        uint8 next = cur + 1;
        _requireTierExists(next);
        _setMemberTier(member, next);
    }

    function demote(address member) external auth(MANAGE_TIERS_PERMISSION_ID) {
        uint8 cur = _currentTier(member);
        if (cur == 0) revert NotAMember(member);
        if (cur == 1) {
            _setMemberTier(member, 0);
        } else {
            _setMemberTier(member, cur - 1);
        }
    }

    // ========= Voting power / totals (snapshot-based) =========

    function votingPowerAt(address account, uint256 snapshotBlock) public view returns (uint256) {
        uint8 t = memberTierAtBlock(account, snapshotBlock);
        if (t == 0) return 0;
        return tierMultiplierAtBlock(t, snapshotBlock);
    }

    function totalVotingPowerAt(uint256 snapshotBlock) public view returns (uint256 total) {
        uint8 tc = tierCountAtBlock(snapshotBlock);
        for (uint8 t = 1; t <= tc; t++) {
            uint256 c = tierMemberCountAtBlock(t, snapshotBlock);
            if (c == 0) continue;
            uint256 m = tierMultiplierAtBlock(t, snapshotBlock);
            total += c * m;
        }
    }

    // ========= Proposals =========

    /// @notice Creates a proposal with actions executed by the DAO if it passes.
    function createProposal(
        bytes calldata metadata,
        IDAO.Action[] calldata actions,
        uint256 allowFailureMap,
        uint64 startDate,
        uint64 endDate
    )
        external
        auth(PROPOSER_PERMISSION_ID)
        returns (uint256 proposalId)
    {
        // Snapshot at previous block to avoid same-block tier/multiplier manipulation.
        uint64 snapshotBlock = uint64(block.number - 1);

        // Require proposer is member at snapshot and meets min proposer power.
        uint256 proposerPower = votingPowerAt(msg.sender, snapshotBlock);
        if (proposerPower == 0) revert NotAMember(msg.sender);
        if (proposerPower < _settings.minProposerPower) {
            revert MinProposerPowerNotMet(msg.sender, proposerPower, _settings.minProposerPower);
        }

        (uint64 s, uint64 e) = _normalizeDates(startDate, endDate);
        if (e <= s) revert InvalidDates(s, e);

        proposalId = _proposalCount;
        _proposalCount++;

        _proposals[proposalId] = ProposalCore({
            startDate: s,
            endDate: e,
            snapshotBlock: snapshotBlock,
            allowFailureMap: allowFailureMap,
            executed: false
        });

        _proposalMetadata[proposalId] = metadata;

        // Store actions
        IDAO.Action[] storage stored = _proposalActions[proposalId];
        for (uint256 i = 0; i < actions.length; i++) {
            stored.push(actions[i]);
        }

        emit ProposalCreated(proposalId, msg.sender, s, e, metadata, actions, allowFailureMap);
    }

    function getProposalCore(uint256 proposalId) external view returns (ProposalCore memory, Tally memory, bytes memory) {
        if (!_exists(proposalId)) revert ProposalDoesNotExist(proposalId);
        return (_proposals[proposalId], _tallies[proposalId], _proposalMetadata[proposalId]);
    }

    function getProposalActions(uint256 proposalId) external view returns (IDAO.Action[] memory) {
        if (!_exists(proposalId)) revert ProposalDoesNotExist(proposalId);
        return _proposalActions[proposalId];
    }

    function vote(uint256 proposalId, VoteOption choice) external {
        if (!_exists(proposalId)) revert ProposalDoesNotExist(proposalId);
        if (choice != VoteOption.Abstain && choice != VoteOption.Yes && choice != VoteOption.No) {
            revert VoteNotAllowed(proposalId);
        }

        ProposalCore memory p = _proposals[proposalId];
        if (block.timestamp < p.startDate || block.timestamp > p.endDate) revert ProposalNotOpen(proposalId);

        uint256 power = votingPowerAt(msg.sender, p.snapshotBlock);
        if (power == 0) revert NoVotingPower(msg.sender);

        VoteOption prev = _voterChoice[proposalId][msg.sender];

        if (prev != VoteOption.None) {
            if (_settings.votingMode != VotingMode.VoteReplacement) {
                revert AlreadyVoted(proposalId, msg.sender);
            }
            // use stored power for consistency (it should equal `power`, but keep it fixed anyway)
            uint256 used = _voterPower[proposalId][msg.sender];
            _removeFromTally(proposalId, prev, used);
            _addToTally(proposalId, choice, used);
            _voterChoice[proposalId][msg.sender] = choice;

            emit VoteCast(proposalId, msg.sender, choice, used);
            return;
        }

        _voterChoice[proposalId][msg.sender] = choice;
        _voterPower[proposalId][msg.sender] = power;

        _addToTally(proposalId, choice, power);

        emit VoteCast(proposalId, msg.sender, choice, power);
    }

    function canExecute(uint256 proposalId) public view returns (bool) {
        if (!_exists(proposalId)) return false;
        ProposalCore memory p = _proposals[proposalId];
        if (p.executed) return false;

        // If early execution, allow before endDate when un-defeatable.
        if (_settings.votingMode == VotingMode.EarlyExecution) {
            if (_isEarlyExecutable(proposalId, p)) return true;
        }

        // Otherwise only after endDate and passed.
        if (block.timestamp < p.endDate) return false;
        return _isPassed(proposalId, p);
    }

    function execute(uint256 proposalId) external nonReentrant {
        if (!_exists(proposalId)) revert ProposalDoesNotExist(proposalId);

        ProposalCore storage p = _proposals[proposalId];
        if (p.executed) revert AlreadyExecuted(proposalId);
        if (!canExecute(proposalId)) revert ProposalNotExecutable(proposalId);

        p.executed = true;

        bytes32 callId = keccak256(abi.encode(address(this), proposalId));
        IDAO.Action[] storage actions = _proposalActions[proposalId];

        dao().execute(callId, actions, p.allowFailureMap);

        emit ProposalExecuted(proposalId);
    }

    // ========= Internal: tiers / members =========

    function _initTiers(uint8 initialTierCount, uint256[] calldata multipliers) internal {
        if (initialTierCount == 0 || initialTierCount > MAX_TIERS) revert InvalidTierCount(initialTierCount);

        _tierCountHistory.push(initialTierCount);
        emit TierCountUpdated(initialTierCount);

        // Init tier member counts to 0 at install
        for (uint8 t = 1; t <= initialTierCount; t++) {
            _tierMemberCountHistory[t].push(0);
        }

        if (multipliers.length != 0 && multipliers.length != initialTierCount) revert InvalidBatchLengths();

        for (uint8 t2 = 1; t2 <= initialTierCount; t2++) {
            uint256 m;
            if (multipliers.length == 0) {
                // default: 1,2,4,8,16...
                m = 1 << (t2 - 1);
            } else {
                m = multipliers[t2 - 1];
            }
            if (m == 0) revert InvalidMultiplier(m);
            _tierMultiplierHistory[t2].push(m);
            emit TierMultiplierUpdated(t2, m);
        }
    }

    function _initMembers(address[] calldata members, uint8[] calldata tiers) internal {
        if (tiers.length != 0 && tiers.length != members.length) revert InvalidBatchLengths();

        if (members.length == 0) return;

        address[] memory added = new address[](members.length);
        uint256 addedCount;

        for (uint256 i = 0; i < members.length; i++) {
            address m = members[i];
            if (m == address(0)) revert InvalidMember(m);
            if (_currentTier(m) != 0) revert InvalidMember(m);

            uint8 tier = tiers.length == 0 ? 1 : tiers[i];
            _requireTierExists(tier);

            _memberTierHistory[m].push(tier);

            // update per-tier member count checkpoint
            uint256 curCount = _tierMemberCountHistory[tier].latest();
            _tierMemberCountHistory[tier].push(curCount + 1);

            emit MemberTierUpdated(m, 0, tier);

            added[addedCount] = m;
            addedCount++;
        }

        // Emit MembersAdded with exact size array
        address[] memory trimmed = new address[](addedCount);
        for (uint256 j = 0; j < addedCount; j++) trimmed[j] = added[j];
        emit MembersAdded(trimmed);
    }

    function _setMemberTier(address member, uint8 newTier) internal {
        if (member == address(0)) revert InvalidMember(member);

        uint8 tc = tierCount();
        if (newTier > tc) revert InvalidTier(newTier);

        uint8 prev = _currentTier(member);
        if (prev == newTier) return;

        // Remove from previous tier count if needed
        if (prev != 0) {
            uint256 prevCount = _tierMemberCountHistory[prev].latest();
            // prevCount should be > 0
            _tierMemberCountHistory[prev].push(prevCount - 1);
        }

        // Add to new tier count if needed
        if (newTier != 0) {
            uint256 newCount = _tierMemberCountHistory[newTier].latest();
            _tierMemberCountHistory[newTier].push(newCount + 1);
        }

        _memberTierHistory[member].push(newTier);

        emit MemberTierUpdated(member, prev, newTier);

        // IMembership events for add/remove
        if (prev == 0 && newTier != 0) {
            address;
            a[0] = member;
            emit MembersAdded(a);
        } else if (prev != 0 && newTier == 0) {
            address;
            r[0] = member;
            emit MembersRemoved(r);
        }
    }

    function _currentTier(address member) internal view returns (uint8) {
        return uint8(_memberTierHistory[member].latest());
    }

    function _requireTierExists(uint8 tier) internal view {
        uint8 tc = tierCount();
        if (tier == 0 || tier > tc) revert InvalidTier(tier);
    }

    // ========= Internal: tallies / passing rules =========

    function _addToTally(uint256 proposalId, VoteOption choice, uint256 power) internal {
        Tally storage t = _tallies[proposalId];
        if (choice == VoteOption.Abstain) t.abstain += power;
        else if (choice == VoteOption.Yes) t.yes += power;
        else if (choice == VoteOption.No) t.no += power;
    }

    function _removeFromTally(uint256 proposalId, VoteOption choice, uint256 power) internal {
        Tally storage t = _tallies[proposalId];
        if (choice == VoteOption.Abstain) t.abstain -= power;
        else if (choice == VoteOption.Yes) t.yes -= power;
        else if (choice == VoteOption.No) t.no -= power;
    }

    function _isPassed(uint256 proposalId, ProposalCore memory p) internal view returns (bool) {
        Tally memory t = _tallies[proposalId];

        uint256 total = totalVotingPowerAt(p.snapshotBlock);
        if (total == 0) return false;

        uint256 participation = t.yes + t.no + t.abstain;
        uint256 minPart = Math.mulDiv(total, _settings.minParticipation, RATIO_BASE);
        if (participation < minPart) return false;

        uint256 yesNo = t.yes + t.no;
        if (yesNo == 0) return false;

        // yes / (yes+no) >= supportThreshold
        // yes * RATIO_BASE >= supportThreshold * (yes+no)
        return t.yes * uint256(RATIO_BASE) >= uint256(_settings.supportThreshold) * yesNo;
    }

    function _isEarlyExecutable(uint256 proposalId, ProposalCore memory p) internal view returns (bool) {
        // must already meet minParticipation, and support must be un-defeatable even if all remaining votes were NO.
        Tally memory t = _tallies[proposalId];

        uint256 total = totalVotingPowerAt(p.snapshotBlock);
        if (total == 0) return false;

        uint256 participation = t.yes + t.no + t.abstain;
        uint256 minPart = Math.mulDiv(total, _settings.minParticipation, RATIO_BASE);
        if (participation < minPart) return false;

        uint256 remaining = total - participation;

        // Worst case: all remaining votes go to NO, so denominator becomes (yes + no + remaining)
        uint256 worstYesNo = t.yes + t.no + remaining;
        if (worstYesNo == 0) return false;

        return t.yes * uint256(RATIO_BASE) >= uint256(_settings.supportThreshold) * worstYesNo;
    }

    // ========= Internal: settings validation =========

    function _setVotingSettings(VotingSettings calldata s) internal {
        // Basic sanity checks
        if (s.supportThreshold > RATIO_BASE) revert;
        if (s.minParticipation > RATIO_BASE) revert;

        if (s.minDuration == 0) revert DurationOutOfBounds(s.minDuration);
        if (s.maxDuration != 0 && s.maxDuration < s.minDuration) revert DurationOutOfBounds(s.maxDuration);

        _settings = s;
    }

    function _normalizeDates(uint64 startDate, uint64 endDate) internal view returns (uint64 s, uint64 e) {
        s = startDate == 0 ? uint64(block.timestamp) : startDate;

        if (endDate == 0) {
            e = s + _settings.minDuration;
        } else {
            e = endDate;
        }

        uint64 duration = e > s ? (e - s) : 0;
        if (duration < _settings.minDuration) revert DurationOutOfBounds(duration);
        if (_settings.maxDuration != 0 && duration > _settings.maxDuration) revert DurationOutOfBounds(duration);
    }

    // ========= Internal: helpers =========

    function _exists(uint256 proposalId) internal view returns (bool) {
        return proposalId < _proposalCount;
    }

    function _getAtBlockOrLatest(CheckpointsUpgradeable.History storage h, uint256 blockNumber) internal view returns (uint256) {
        if (blockNumber == 0) return h.latest();
        return h.getAtBlock(blockNumber);
    }
}
