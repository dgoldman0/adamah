# TODO — TieredMembershipVoting (Aragon OSx, UUPS)

This repo will implement a modern Aragon OSx governance plugin:
membership-based voting with **tiered voting power**, **tier multipliers**, **promote/demote**, and **add tiers (up to 5)**.
All changes are performed **by proposals executed through the same plugin**.

---

## 0) Scope + assumptions

- Target: **Aragon OSx** plugin architecture + **UUPS (ERC1967) proxy instances**
- Governance model: **weighted majority voting** (Yes/No/Abstain)
- Voting power = `multiplier[tier(member)]` at **proposal snapshot**
- Default: 5 tiers, multipliers doubling (1,2,4,8,16), but configurable at init and adjustable later by governance
- Tier management, multiplier updates, and member promotions/demotions are only callable by **DAO (via execution)**
- Snapshots must ensure mid-proposal tier changes do not affect ongoing proposals

---

## 1) Repo scaffolding

- [ ] Create project structure:
  - `contracts/`
  - `contracts/condition/`
  - `test/`
  - `script/` (deploy/verify)
  - `README.md`
  - `TODO.md` (this file)
- [ ] Pick toolchain: Foundry preferred (fast + common in OSx repos)
- [ ] Add dependencies:
  - Aragon OSx core + framework (matching intended network / release)
  - OpenZeppelin upgradeable libs (UUPS + checkpoints)
- [ ] Configure formatting/linting:
  - `forge fmt`, `solhint` (optional), `slither` config stub

---

## 2) Core contracts (Build 1)

### 2.1 TieredMembershipVoting.sol (UUPS plugin implementation)

- [ ] Inherit correct OSx UUPS plugin base:
  - UUPS upgrade authorization via `UPGRADE_PLUGIN_PERMISSION_ID`
- [ ] Define permission IDs:
  - `PROPOSER_PERMISSION_ID`
  - `UPDATE_VOTING_SETTINGS_PERMISSION_ID`
  - `MANAGE_TIERS_PERMISSION_ID` (covers add tier, multipliers, member tier changes)
  - (optional) `EXECUTE_PROPOSAL_PERMISSION_ID` if you want execution gated
- [ ] Define governance settings struct:
  - `supportThreshold` (Yes/(Yes+No))
  - `minParticipation` ((Yes+No+Abstain)/total)
  - `minDuration`, `maxDuration`
  - `minProposerPower` (absolute voting power requirement)
  - `votingMode` (Standard / EarlyExecution / VoteReplacement)
- [ ] Implement tier system:
  - [ ] `MAX_TIERS = 5`
  - [ ] `tierCount` checkpointed (monotonic increase up to 5)
  - [ ] `tierMultiplier[t]` checkpointed
  - [ ] `tierMemberCount[t]` checkpointed
  - [ ] Member tier checkpointed (`tier=0` == non-member)
  - [ ] Functions (permissioned to DAO):
    - `addTier(multiplierOr0)`
    - `setTierMultiplier(tier, multiplier)`
    - `batchSetTierMultipliers(...)`
    - `setMemberTier(member, tierOr0)`
    - `batchSetMemberTier(...)`
    - `promote(member)` / `demote(member)`
- [ ] Proposal model:
  - [ ] Store proposal core:
    - start/end timestamps
    - `snapshotBlock = block.number - 1`
    - `allowFailureMap`
    - `executed`
  - [ ] Store `actions[]` (IDAO.Action)
  - [ ] Store tally (yes/no/abstain) and per-voter state
  - [ ] Implement:
    - `createProposal(metadata, actions, allowFailureMap, startDate, endDate)`
    - `vote(proposalId, choice)`
    - `execute(proposalId)` -> calls `dao.execute(...)`
    - `canExecute(proposalId)`
    - getters: `proposalCount`, `getProposalCore`, `getProposalActions`
- [ ] Snapshot voting power:
  - [ ] `votingPowerAt(account, snapshotBlock)` = multiplier(tier(account,snapshot), snapshot)
  - [ ] `totalVotingPowerAt(snapshotBlock)` = sum over tiers: count(t,snapshot) * multiplier(t,snapshot)
- [ ] Passing logic:
  - [ ] Participation >= minParticipation
  - [ ] Support >= supportThreshold
  - [ ] Early execution if enabled (mathematically un-defeatable)
- [ ] Event coverage:
  - [ ] proposal created / executed
  - [ ] vote cast
  - [ ] tier count changed
  - [ ] multiplier changed
  - [ ] member tier changed
  - [ ] settings changed
  - [ ] membership events (MembersAdded/Removed + MembershipContractAnnounced) if implementing IMembership

### 2.2 TieredProposerCondition.sol (conditional proposer gating)

- [ ] Implement OSx PermissionCondition interface
- [ ] `isGranted` returns true if:
  - caller has non-zero voting power at `block.number - 1`
  - caller’s power >= `minProposerPower`
  - (optional) caller tier >= `minProposerTier` if you add that setting later
- [ ] Keep it minimal and dependency-light

### 2.3 TieredMembershipVotingSetup.sol (PluginSetup)

- [ ] Store immutable `implementation` address
- [ ] `prepareInstallation(dao, data)`:
  - [ ] decode init payload:
    - settings
    - initial tier count
    - initial multipliers (optional)
    - initial members + tiers (optional)
  - [ ] deploy ERC1967 proxy with initData (UUPS)
  - [ ] deploy proposer condition helper
  - [ ] return helpers + permissions list
- [ ] `prepareUninstallation(dao, payload)`:
  - [ ] revoke all grants added at install

---

## 3) Permission plan (install-time)

- [ ] Grant DAO `EXECUTE_PERMISSION_ID` -> plugin instance (so plugin can execute actions)
- [ ] Grant plugin `UPGRADE_PLUGIN_PERMISSION_ID` -> DAO (so upgrades happen “by governance”)
- [ ] Grant plugin `UPDATE_VOTING_SETTINGS_PERMISSION_ID` -> DAO
- [ ] Grant plugin `MANAGE_TIERS_PERMISSION_ID` -> DAO
- [ ] Grant plugin `PROPOSER_PERMISSION_ID` -> ANY_ADDR with `TieredProposerCondition`

Optional:
- [ ] Decide whether `execute(proposalId)` is permissionless
  - If permissionless, no extra permission needed (still checks `canExecute`)
  - If gated, add `EXECUTE_PROPOSAL_PERMISSION_ID` and grant it to ANY_ADDR

---

## 4) Upgradeability (UUPS)

- [ ] Follow upgrade-safe storage layout rules:
  - append-only state
  - reserved `__gap` where appropriate
- [ ] Implement `_authorizeUpgrade(newImplementation)` with `auth(UPGRADE_PLUGIN_PERMISSION_ID)`
- [ ] Implement `initializeFrom(uint16 fromBuild, bytes calldata payload)` reinitializer pattern for updates
- [ ] Add `prepareUpdate(...)` in Setup contract (Build 2+):
  - returns `initData` for `upgradeToAndCall`
  - returns any permission diffs if needed

---

## 5) Tests (must-have)

### 5.1 Installation tests
- [ ] Install plugin via Setup
- [ ] Assert permissions are granted correctly
- [ ] Assert tierCount/multipliers initialized correctly (default and custom)
- [ ] Assert initial membership tiers applied correctly

### 5.2 Voting + snapshot correctness
- [ ] Create proposal at T0, snapshotBlock captured
- [ ] Promote member after proposal creation
- [ ] Vote power remains based on snapshot, not new tier
- [ ] Change multiplier after proposal creation
- [ ] Vote power remains based on snapshot multiplier
- [ ] totalVotingPowerAt(snapshot) remains stable

### 5.3 Passing rules
- [ ] Support threshold pass/fail
- [ ] Participation threshold pass/fail
- [ ] Early execution: becomes executable before endDate once un-defeatable
- [ ] Vote replacement: second vote overwrites tally

### 5.4 Governance-mutating actions
- [ ] Proposal that calls:
  - `setTierMultiplier`
  - `addTier`
  - `promote/demote`
  - `setMemberTier`
- [ ] Ensure actions can only be called by DAO (direct EOA call fails)

### 5.5 Execution
- [ ] Proposal executes actions via `dao.execute`
- [ ] allowFailureMap behavior (at least a couple cases)

### 5.6 Upgrade tests
- [ ] Deploy Build 1, create proposals and state
- [ ] Upgrade to Build 2 with `upgradeToAndCall`
- [ ] Confirm state preserved
- [ ] Confirm new functionality reachable
- [ ] Confirm only DAO (permissioned) can upgrade

---

## 6) Gas + safety hardening

- [ ] Cap tiers at 5 (already) and validate all tier inputs
- [ ] Validate multipliers:
  - non-zero
  - enforce sane upper bound (pick a max and document it)
- [ ] Validate membership operations:
  - no zero address
  - consistent tier counts
  - batch length checks
- [ ] Reentrancy protection on `execute`
- [ ] Prevent proposal ID collisions and ensure action array copying is safe
- [ ] Consider griefing limits:
  - max actions per proposal (optional)
  - metadata size constraints (optional)

---

## 7) App/UX integration

- [ ] Define initialization payload schema for frontend
- [ ] Define settings/tier view helpers:
  - current tierCount
  - list multipliers for active tiers
  - member tier lookup
  - proposal snapshot info
- [ ] Add events indexable for:
  - promotions/demotions
  - multiplier changes
  - tier additions
- [ ] Provide example calldata builders for:
  - add member
  - promote/demote
  - change multiplier
  - add tier

---

## 8) Deployment + publishing

- [ ] Deployment scripts:
  - deploy implementation
  - deploy Setup contract
  - publish to PluginRepo (if you’re using a repo on-chain)
- [ ] Verify contracts
- [ ] Tag release as Build 1
- [ ] Add security checklist for audits

---

## 9) Open questions to resolve (write decisions into README once picked)

- [ ] Are members stored purely via checkpointed `memberTierHistory`, or also tracked in an enumerable set?
  - If you need listing members on-chain, you’ll need an enumerable set (or off-chain index).
- [ ] Do we allow “remove member” as tier=0, or maintain a separate membership flag?
- [ ] Should proposer gating include `minProposerTier` in addition to `minProposerPower`?
- [ ] Do we gate execution (permissioned) or allow anyone to execute if passed?
- [ ] Any special tie-breaking (e.g., yes == no fails)?
- [ ] Any tier-specific quorum/support (likely avoid for Build 1)

---
