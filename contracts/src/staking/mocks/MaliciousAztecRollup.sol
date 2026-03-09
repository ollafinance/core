// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@oz/utils/Address.sol";
import { IERC20Mintable } from "src/interfaces/IERC20Mintable.sol";
import { AttesterConfig, AttesterView, Exit, Status, Timestamp } from "src/staking/libraries/AztecTypes.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";
import { IMaliciousAztecRollup } from "src/staking/mocks/IMaliciousAztecRollup.sol";
import { IMockAztecRollup } from "src/staking/mocks/IMockAztecRollup.sol";

/// @title MaliciousAztecRollup
/// @notice Test-only rollup mock that attempts reentrancy on selected entrypoints.
/// @author Olla Core contributors
contract MaliciousAztecRollup is IMaliciousAztecRollup {
    using Address for address;
    using SafeERC20 for IERC20;

    /// @notice Maximum basis points value (100%).
    uint256 public constant MAX_BPS = 10_000;

    /// @notice Default activation threshold used when constructor arg is 0.
    uint256 public constant DEFAULT_ACTIVATION_THRESHOLD = 200_000e18;

    uint8 private constant _REENTER_ON_DEPOSIT = 1 << 0;
    uint8 private constant _REENTER_ON_INITIATE_WITHDRAW = 1 << 1;
    uint8 private constant _REENTER_ON_FINALIZE_WITHDRAW = 1 << 2;
    uint8 private constant _REENTER_ON_CLAIM_REWARDS = 1 << 3;

    /// @notice The staking asset token.
    IERC20 public immutable override STAKING_ASSET;
    uint256 private _activationThreshold;

    /// @notice Stake amount per attester.
    mapping(address attester => uint256 stake) public override stakes;

    /// @notice Withdrawer address per attester.
    mapping(address attester => address withdrawer) public override withdrawers;
    mapping(address attester => Exit exit) private _exits;
    mapping(address attester => G1Point publicKey) private _publicKeys;
    /// @notice Pending rewards per sequencer/coinbase.
    mapping(address sequencer => uint256 rewards) public override pendingRewards;

    /// @notice Whether claiming should fail for a sequencer/coinbase.
    mapping(address sequencer => bool shouldFail) public override claimShouldFail;

    /// @notice Rewards accrued per second when `tick` is called.
    uint256 public rewardRatePerSecond;
    /// @notice Last timestamp used for reward accrual.
    uint256 public lastTick;

    /// @notice Recipient used for tick() reward accrual.
    address public rewardsCoinbase;

    /// @notice Target called during reentrancy.
    address public reentryTarget;

    /// @notice Calldata used during reentrancy.
    bytes public reentryCalldata;

    /// @notice Reentrancy flags for test scenarios.
    /// @dev Packed into a single uint8 to reduce state count.
    uint8 private _reenterFlags;

    constructor(IERC20 stakingAsset, uint256 activationThreshold) {
        STAKING_ASSET = stakingAsset;
        _activationThreshold = activationThreshold == 0 ? DEFAULT_ACTIVATION_THRESHOLD : activationThreshold;
        lastTick = block.timestamp;
    }

    /// @notice Configure the call to perform during a reentrancy attempt.
    /// @param target The contract to call.
    /// @param data The calldata to use.
    /// @inheritdoc IMaliciousAztecRollup
    function setReentry(address target, bytes calldata data) external override {
        reentryTarget = target;
        reentryCalldata = data;
    }

    /// @notice Enable/disable a reentrancy attempt during `deposit`.
    /// @param enabled Whether reentrancy is enabled.
    /// @inheritdoc IMaliciousAztecRollup
    function setReenterOnDeposit(bool enabled) external override {
        if (enabled) {
            _reenterFlags |= _REENTER_ON_DEPOSIT;
        } else {
            _reenterFlags &= ~_REENTER_ON_DEPOSIT;
        }
    }

    /// @notice Enable/disable a reentrancy attempt during `initiateWithdraw`.
    /// @param enabled Whether reentrancy is enabled.
    /// @inheritdoc IMaliciousAztecRollup
    function setReenterOnInitiateWithdraw(bool enabled) external override {
        if (enabled) {
            _reenterFlags |= _REENTER_ON_INITIATE_WITHDRAW;
        } else {
            _reenterFlags &= ~_REENTER_ON_INITIATE_WITHDRAW;
        }
    }

    /// @notice Enable/disable a reentrancy attempt during `finalizeWithdraw`.
    /// @param enabled Whether reentrancy is enabled.
    /// @inheritdoc IMaliciousAztecRollup
    function setReenterOnFinalizeWithdraw(bool enabled) external override {
        if (enabled) {
            _reenterFlags |= _REENTER_ON_FINALIZE_WITHDRAW;
        } else {
            _reenterFlags &= ~_REENTER_ON_FINALIZE_WITHDRAW;
        }
    }

    /// @notice Enable/disable a reentrancy attempt during `claimSequencerRewards`.
    /// @param enabled Whether reentrancy is enabled.
    /// @inheritdoc IMaliciousAztecRollup
    function setReenterOnClaimSequencerRewards(bool enabled) external override {
        if (enabled) {
            _reenterFlags |= _REENTER_ON_CLAIM_REWARDS;
        } else {
            _reenterFlags &= ~_REENTER_ON_CLAIM_REWARDS;
        }
    }

    /// @notice Deposit stake for an attester.
    /// @param _attester The attester address.
    /// @param _withdrawer The withdrawer address.
    /// @param _publicKeyInG1 The public key in G1.
    /// @param _publicKeyInG2 The public key in G2.
    /// @param _proofOfPossession The proof of possession.
    /// @param _onCanonical Whether to stake on canonical chain.
    function deposit(
        address _attester,
        address _withdrawer,
        G1Point calldata _publicKeyInG1,
        G2Point calldata _publicKeyInG2,
        G1Point calldata _proofOfPossession,
        bool _onCanonical
    ) external override {
        _onCanonical;
        if ((_reenterFlags & _REENTER_ON_DEPOSIT) != 0) {
            _reenterFlags &= ~_REENTER_ON_DEPOSIT;
            reentryTarget.functionCall(reentryCalldata);
        }

        STAKING_ASSET.safeTransferFrom(msg.sender, address(this), _activationThreshold);
        stakes[_attester] = _activationThreshold;
        withdrawers[_attester] = _withdrawer;
        _publicKeys[_attester] = _publicKeyInG1;
        emit Deposit(_attester, _withdrawer, _publicKeyInG1, _publicKeyInG2, _proofOfPossession, _activationThreshold);
    }

    /// @notice Initiate a withdrawal for an attester.
    /// @param _attester The attester address.
    /// @param _recipient The recipient address.
    /// @return success Whether the withdrawal was initiated.
    function initiateWithdraw(address _attester, address _recipient) external override returns (bool success) {
        if ((_reenterFlags & _REENTER_ON_INITIATE_WITHDRAW) != 0) {
            _reenterFlags &= ~_REENTER_ON_INITIATE_WITHDRAW;
            reentryTarget.functionCall(reentryCalldata);
        }

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

        _exits[_attester] = Exit({
            withdrawalId: 0,
            amount: amount,
            exitableAt: Timestamp.wrap(block.timestamp),
            recipientOrWithdrawer: _recipient,
            isRecipient: true,
            exists: true
        });

        emit WithdrawInitiated(_attester, _recipient, amount);
        return true;
    }

    /// @notice Finalize a withdrawal for an attester.
    /// @param _attester The attester address.
    function finalizeWithdraw(address _attester) external override {
        if ((_reenterFlags & _REENTER_ON_FINALIZE_WITHDRAW) != 0) {
            _reenterFlags &= ~_REENTER_ON_FINALIZE_WITHDRAW;
            reentryTarget.functionCall(reentryCalldata);
        }

        Exit memory exit = _exits[_attester];
        if (!exit.exists) {
            revert MockAztecRollup__NotExiting();
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

    /// @notice Claim sequencer rewards for a coinbase.
    /// @param _coinbase The coinbase address.
    /// @return amount The amount claimed.
    function claimSequencerRewards(address _coinbase) external override returns (uint256 amount) {
        if ((_reenterFlags & _REENTER_ON_CLAIM_REWARDS) != 0) {
            _reenterFlags &= ~_REENTER_ON_CLAIM_REWARDS;
            reentryTarget.functionCall(reentryCalldata);
        }

        if (claimShouldFail[_coinbase]) {
            revert MockAztecRollup__ClaimFailed();
        }
        amount = pendingRewards[_coinbase];
        if (amount > 0) {
            pendingRewards[_coinbase] = 0;
            IERC20Mintable(address(STAKING_ASSET)).mint(_coinbase, amount);
            emit RewardsClaimed(_coinbase, _coinbase, amount);
        }
        return amount;
    }

    /// @inheritdoc IMockAztecRollup
    function tick(address coinbase) external override returns (uint256 added) {
        uint256 dt = block.timestamp - lastTick;
        if (dt == 0) return 0;

        added = rewardRatePerSecond * dt;
        if (added > 0) {
            pendingRewards[coinbase] += added;
        }
        lastTick = block.timestamp;
    }

    /// @inheritdoc IMockAztecRollup
    function setRewardRatePerSecond(uint256 newRate) external override {
        rewardRatePerSecond = newRate;
    }

    /// @inheritdoc IMockAztecRollup
    function addRewards(address coinbase, uint256 amount) external override {
        pendingRewards[coinbase] += amount;
    }

    /// @inheritdoc IMockAztecRollup
    function setRewardsCoinbase(address coinbase) external override {
        rewardsCoinbase = coinbase;
    }

    /// @notice Set pending rewards for a sequencer.
    /// @param _sequencer The sequencer address.
    /// @param _amount The reward amount.
    function setRewards(address _sequencer, uint256 _amount) external override {
        pendingRewards[_sequencer] = _amount;
    }

    /// @notice Set the activation threshold.
    /// @param _threshold The new activation threshold.
    function setActivationThreshold(uint256 _threshold) external override {
        _activationThreshold = _threshold;
    }

    /// @notice Mark an exit as ready.
    /// @param _attester The attester address.
    /// @param _exitableAt The exitable timestamp.
    function setExitReady(address _attester, uint256 _exitableAt) external override {
        if (_exits[_attester].exists) {
            _exits[_attester].exitableAt = Timestamp.wrap(_exitableAt);
        }
    }

    /// @notice Set an external exit record.
    /// @param _attester The attester address.
    /// @param _amount The exit amount.
    /// @param _exitableAt The exitable timestamp.
    function setExternalExit(address _attester, uint256 _amount, uint256 _exitableAt) external override {
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

    /// @notice Configure whether `claimSequencerRewards` reverts for a sequencer.
    /// @param _sequencer The sequencer address.
    /// @param _shouldFail Whether to revert.
    function setClaimShouldFail(address _sequencer, bool _shouldFail) external override {
        claimShouldFail[_sequencer] = _shouldFail;
    }

    /// @inheritdoc IMockAztecRollup
    function setExitRecipient(address _attester, address _recipient) external override {
        if (_exits[_attester].exists) {
            _exits[_attester].recipientOrWithdrawer = _recipient;
            _exits[_attester].isRecipient = true;
        }
    }

    /// @inheritdoc IMockAztecRollup
    function setStake(address _attester, uint256 _amount, address _withdrawer) external override {
        stakes[_attester] = _amount;
        withdrawers[_attester] = _withdrawer;
    }

    /// @inheritdoc IMockAztecRollup
    function clearAttester(address _attester) external override {
        stakes[_attester] = 0;
        delete _exits[_attester];
    }

    /// @notice Get the exit record for an attester.
    /// @param _attester The attester address.
    /// @return The exit record.
    function getExit(address _attester) external view override returns (Exit memory) {
        return _exits[_attester];
    }

    /// @notice Get the attester status.
    /// @param _attester The attester address.
    /// @return The attester status.
    function getStatus(address _attester) external view override returns (Status) {
        if (_exits[_attester].exists) {
            return _exits[_attester].isRecipient ? Status.EXITING : Status.ZOMBIE;
        }
        return stakes[_attester] > 0 ? Status.VALIDATING : Status.NONE;
    }

    /// @notice Get the activation threshold.
    /// @return The activation threshold.
    function getActivationThreshold() external view override returns (uint256) {
        return _activationThreshold;
    }

    /// @notice Get pending rewards for a sequencer.
    /// @param _sequencer The sequencer address.
    /// @return The pending reward amount.
    function getSequencerRewards(address _sequencer) external view override returns (uint256) {
        return pendingRewards[_sequencer];
    }

    /// @notice Get the attester view.
    /// @param _attester The attester address.
    /// @return The attester view.
    function getAttesterView(address _attester) external view override returns (AttesterView memory) {
        Exit memory exit = _exits[_attester];
        Status status;
        uint256 effectiveBalance;

        if (exit.exists) {
            status = exit.isRecipient ? Status.EXITING : Status.ZOMBIE;
            effectiveBalance = 0;
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

    /// @notice Get the activated attester count.
    /// @return The activated attester count.
    function getActivatedAttesterCount() external pure override returns (uint256) {
        return 0;
    }
}
