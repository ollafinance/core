// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { IERC20Mintable } from "src/interfaces/IERC20Mintable.sol";
import {
    AttesterConfig,
    AttesterView,
    DepositArgs,
    Exit,
    Status,
    Timestamp
} from "src/staking/libraries/AztecTypes.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";
import { IMockAztecRollup } from "src/staking/mocks/IMockAztecRollup.sol";

/// @title MockAztecRollup
/// @notice Mock Aztec rollup for testing staking flows.
/// @dev Implements a subset of IStaking interface for testing.
/// @author Olla Core contributors
contract MockAztecRollup is IMockAztecRollup {
    using SafeERC20 for IERC20;

    struct RewardState {
        uint256 rewardRatePerSecond;
        uint256 lastTick;
        address rewardsCoinbase;
        bool useTransferMode;
    }

    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Default activation threshold used when constructor arg is 0.
    uint256 public constant DEFAULT_ACTIVATION_THRESHOLD = 200_000e18;

    /// @notice Maximum basis points value (100%).
    uint256 public constant MAX_BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMockAztecRollup
    IERC20 public immutable STAKING_ASSET;
    uint256 private _activationThreshold;

    /// @inheritdoc IMockAztecRollup
    mapping(address attester => uint256 stake) public stakes;
    /// @notice Total stake currently active on the rollup.
    uint256 public totalStaked;
    /// @inheritdoc IMockAztecRollup
    mapping(address attester => address withdrawer) public withdrawers;
    mapping(address attester => Exit exit) private _exits;
    mapping(address attester => G1Point publicKey) private _publicKeys;
    /// @inheritdoc IMockAztecRollup
    mapping(address sequencer => uint256 rewards) public pendingRewards;
    /// @inheritdoc IMockAztecRollup
    mapping(address sequencer => bool shouldFail) public claimShouldFail;
    /// @inheritdoc IMockAztecRollup
    mapping(address sequencer => bool shouldFail) public getRewardsShouldFail;

    /// @inheritdoc IMockAztecRollup
    bool public isRewardsClaimable;

    RewardState private _rewardState;

    /// @notice Tracked count of activated attesters.
    uint256 private _activatedAttesterCount;

    /// @notice Configurable exit delay for initiateWithdraw (default 0 = immediate).
    uint256 public exitDelay;

    /// @notice Mock entry queue for testing purgeFailedQueueEntry.
    address[] private _entryQueue;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IERC20 stakingAsset, uint256 activationThreshold) {
        STAKING_ASSET = stakingAsset;
        _activationThreshold = activationThreshold == 0 ? DEFAULT_ACTIVATION_THRESHOLD : activationThreshold;
        _rewardState.lastTick = block.timestamp;
        isRewardsClaimable = true;
    }

    /*//////////////////////////////////////////////////////////////
                            STAKING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMockAztecRollup
    function deposit(
        address _attester,
        address _withdrawer,
        G1Point calldata _publicKeyInG1,
        G2Point calldata _publicKeyInG2,
        G1Point calldata _proofOfPossession,
        bool
    ) external override {
        uint256 previousStake = stakes[_attester];
        STAKING_ASSET.safeTransferFrom(msg.sender, address(this), _activationThreshold);
        stakes[_attester] = _activationThreshold;
        if (previousStake > 0) {
            totalStaked = totalStaked - previousStake + _activationThreshold;
        } else {
            totalStaked += _activationThreshold;
        }
        withdrawers[_attester] = _withdrawer;
        _publicKeys[_attester] = _publicKeyInG1;
        if (previousStake == 0) {
            ++_activatedAttesterCount;
        }
        emit Deposit(_attester, _withdrawer, _publicKeyInG1, _publicKeyInG2, _proofOfPossession, _activationThreshold);
    }

    /// @inheritdoc IMockAztecRollup
    function initiateWithdraw(address _attester, address _recipient) external override returns (bool) {
        if (withdrawers[_attester] != msg.sender) {
            revert MockAztecRollup__NotWithdrawer();
        }
        // Zombie exit (isRecipient=false): claim it by setting recipient
        if (_exits[_attester].exists) {
            if (!_exits[_attester].isRecipient) {
                _exits[_attester].recipientOrWithdrawer = _recipient;
                _exits[_attester].isRecipient = true;
                return true;
            }
            revert MockAztecRollup__AlreadyExiting();
        }

        uint256 amount = stakes[_attester];
        stakes[_attester] = 0;
        if (amount > 0) {
            totalStaked -= amount;
        }

        _exits[_attester] = Exit({
            withdrawalId: 0,
            amount: amount,
            exitableAt: Timestamp.wrap(block.timestamp + exitDelay),
            recipientOrWithdrawer: _recipient,
            isRecipient: true,
            exists: true
        });

        emit WithdrawInitiated(_attester, _recipient, amount);
        return true;
    }

    /// @inheritdoc IMockAztecRollup
    function finalizeWithdraw(address _attester) external override {
        Exit memory exit = _exits[_attester];
        if (!exit.exists) {
            revert MockAztecRollup__NotExiting();
        }
        if (!exit.isRecipient) {
            revert MockAztecRollup__InitiateWithdrawNeeded();
        }
        if (Timestamp.unwrap(exit.exitableAt) > block.timestamp) {
            revert MockAztecRollup__NotReady();
        }

        uint256 amount = exit.amount;
        stakes[_attester] = 0;
        delete _exits[_attester];

        STAKING_ASSET.safeTransfer(exit.recipientOrWithdrawer, amount);
        emit WithdrawFinalized(_attester, exit.recipientOrWithdrawer, amount);
    }

    /// @inheritdoc IMockAztecRollup
    function claimSequencerRewards(address _coinbase) external override returns (uint256) {
        if (!isRewardsClaimable) {
            revert MockAztecRollup__ClaimFailed();
        }
        if (claimShouldFail[_coinbase]) {
            revert MockAztecRollup__ClaimFailed();
        }
        uint256 amount = pendingRewards[_coinbase];
        if (amount > 0) {
            pendingRewards[_coinbase] = 0;
            if (_rewardState.useTransferMode) {
                STAKING_ASSET.safeTransfer(_coinbase, amount);
            } else {
                IERC20Mintable(address(STAKING_ASSET)).mint(_coinbase, amount);
            }
            emit RewardsClaimed(_coinbase, _coinbase, amount);
        }
        return amount;
    }

    /*//////////////////////////////////////////////////////////////
                             REWARD ACCRUAL
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMockAztecRollup
    function tick(address coinbase) external override returns (uint256 added) {
        uint256 dt = block.timestamp - _rewardState.lastTick;
        if (dt == 0) return 0;

        added = _rewardState.rewardRatePerSecond * dt;
        if (added > 0) {
            pendingRewards[coinbase] += added;
        }
        _rewardState.lastTick = block.timestamp;
    }

    /// @inheritdoc IMockAztecRollup
    function setRewardRatePerSecond(uint256 newRate) external override {
        _rewardState.rewardRatePerSecond = newRate;
    }

    /// @inheritdoc IMockAztecRollup
    function addRewards(address coinbase, uint256 amount) external override {
        pendingRewards[coinbase] += amount;
    }

    /// @inheritdoc IMockAztecRollup
    function setRewardsCoinbase(address coinbase) external override {
        _rewardState.rewardsCoinbase = coinbase;
    }

    /*//////////////////////////////////////////////////////////////
                             TEST HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMockAztecRollup
    function setUseTransferMode(bool _enabled) external override {
        _rewardState.useTransferMode = _enabled;
    }

    /// @inheritdoc IMockAztecRollup
    function setActivatedAttesterCount(uint256 _count) external override {
        _activatedAttesterCount = _count;
    }

    /// @inheritdoc IMockAztecRollup
    function setRewards(address _sequencer, uint256 _amount) external override {
        pendingRewards[_sequencer] = _amount;
    }

    /// @inheritdoc IMockAztecRollup
    function setActivationThreshold(uint256 _threshold) external override {
        _activationThreshold = _threshold;
    }

    /// @inheritdoc IMockAztecRollup
    function setExitReady(address _attester, uint256 _exitableAt) external override {
        if (_exits[_attester].exists) {
            _exits[_attester].exitableAt = Timestamp.wrap(_exitableAt);
        }
    }

    /// @inheritdoc IMockAztecRollup
    function setExternalExit(address _attester, uint256 _amount, uint256 _exitableAt) external override {
        // Decrement totalStaked to mirror what initiateWithdraw does,
        // so the rollup's view stays consistent with the protocol's.
        uint256 currentStake = stakes[_attester];
        if (currentStake > 0) {
            totalStaked -= currentStake;
            stakes[_attester] = 0;
        }

        address withdrawer = withdrawers[_attester];
        if (withdrawer == address(0)) {
            withdrawer = address(this);
        }
        _exits[_attester] = Exit({
            withdrawalId: 0,
            amount: _amount,
            exitableAt: Timestamp.wrap(_exitableAt),
            recipientOrWithdrawer: withdrawer,
            isRecipient: false,
            exists: true
        });
    }

    /// @inheritdoc IMockAztecRollup
    function setExitRecipient(address _attester, address _recipient) external override {
        if (_exits[_attester].exists) {
            _exits[_attester].recipientOrWithdrawer = _recipient;
            _exits[_attester].isRecipient = true;
        }
    }

    /// @inheritdoc IMockAztecRollup
    function setClaimShouldFail(address _sequencer, bool _shouldFail) external override {
        claimShouldFail[_sequencer] = _shouldFail;
    }

    /// @inheritdoc IMockAztecRollup
    function setGetRewardsShouldFail(address _sequencer, bool _shouldFail) external override {
        getRewardsShouldFail[_sequencer] = _shouldFail;
    }

    /// @inheritdoc IMockAztecRollup
    function setRewardsClaimable(bool _claimable) external override {
        isRewardsClaimable = _claimable;
    }

    /// @inheritdoc IMockAztecRollup
    function setStake(address _attester, uint256 _amount, address _withdrawer) external override {
        stakes[_attester] = _amount;
        withdrawers[_attester] = _withdrawer;
    }

    /// @inheritdoc IMockAztecRollup
    function clearAttester(address _attester) external override {
        uint256 currentStake = stakes[_attester];
        if (currentStake > 0) {
            totalStaked -= currentStake;
        }
        // Decrement activated count if the attester was previously deposited
        if (currentStake > 0 || _exits[_attester].exists || withdrawers[_attester] != address(0)) {
            if (_activatedAttesterCount > 0) {
                --_activatedAttesterCount;
            }
        }
        stakes[_attester] = 0;
        // Keep withdrawer set -- on the real rollup, GSE.configOf retains the
        // withdrawer after removal.  Clearing it would make a removed attester
        // indistinguishable from a queued (never-activated) one.
        delete _exits[_attester];
        delete _publicKeys[_attester];
    }

    /*//////////////////////////////////////////////////////////////
                          EXIT DELAY HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMockAztecRollup
    function reduceExitAmount(address _attester, uint256 _newAmount) external override {
        if (!_exits[_attester].exists) {
            revert MockAztecRollup__NoExit();
        }
        if (_newAmount > _exits[_attester].amount) {
            revert MockAztecRollup__InvalidExitAmount();
        }
        _exits[_attester].amount = _newAmount;
    }

    /// @inheritdoc IMockAztecRollup
    function setExitDelay(uint256 _delay) external override {
        exitDelay = _delay;
    }

    /// @inheritdoc IMockAztecRollup
    function addToEntryQueue(address _attester) external override {
        _entryQueue.push(_attester);
    }

    /// @inheritdoc IMockAztecRollup
    function clearEntryQueue() external override {
        delete _entryQueue;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMockAztecRollup
    function getExit(address _attester) external view override returns (Exit memory) {
        return _exits[_attester];
    }

    /// @inheritdoc IMockAztecRollup
    function getStatus(address _attester) external view override returns (Status) {
        if (_exits[_attester].exists) {
            return _exits[_attester].isRecipient ? Status.EXITING : Status.ZOMBIE;
        }
        return stakes[_attester] > 0 ? Status.VALIDATING : Status.NONE;
    }

    /// @inheritdoc IMockAztecRollup
    function getActivationThreshold() external view override returns (uint256) {
        return _activationThreshold;
    }

    /// @inheritdoc IMockAztecRollup
    function getSequencerRewards(address _sequencer) external view override returns (uint256) {
        if (getRewardsShouldFail[_sequencer]) {
            revert MockAztecRollup__ClaimFailed();
        }
        return pendingRewards[_sequencer];
    }

    /// @inheritdoc IMockAztecRollup
    function getAttesterView(address _attester) external view override returns (AttesterView memory) {
        Exit memory exit = _exits[_attester];
        Status status;
        uint256 effectiveBalance;

        if (exit.exists) {
            status = exit.isRecipient ? Status.EXITING : Status.ZOMBIE;
            effectiveBalance = 0; // Funds are in exit.amount when exiting
        } else if (stakes[_attester] > 0) {
            status = Status.VALIDATING;
            effectiveBalance = stakes[_attester];
        } else {
            status = Status.NONE;
            effectiveBalance = 0;
        }

        return AttesterView({
            status: status,
            effectiveBalance: effectiveBalance,
            exit: exit,
            config: AttesterConfig({ publicKey: _publicKeys[_attester], withdrawer: withdrawers[_attester] })
        });
    }

    /// @inheritdoc IMockAztecRollup
    function getActivatedAttesterCount() external view override returns (uint256) {
        return _activatedAttesterCount;
    }

    /// @inheritdoc IMockAztecRollup
    function getEntryQueueLength() external view override returns (uint256) {
        return _entryQueue.length;
    }

    /// @inheritdoc IMockAztecRollup
    function getEntryQueueAt(uint256 _index) external view override returns (DepositArgs memory) {
        address attester = _entryQueue[_index];
        return DepositArgs({
            attester: attester,
            withdrawer: address(0),
            publicKeyInG1: G1Point({ x: 0, y: 0 }),
            publicKeyInG2: G2Point({ x0: 0, x1: 0, y0: 0, y1: 0 }),
            proofOfPossession: G1Point({ x: 0, y: 0 }),
            moveWithLatestRollup: false
        });
    }

    /// @inheritdoc IMockAztecRollup
    function rewardsCoinbase() external view override returns (address coinbase) {
        coinbase = _rewardState.rewardsCoinbase;
    }
}
