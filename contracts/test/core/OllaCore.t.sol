// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { Initializable } from "@oz-upgradeable/proxy/utils/Initializable.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@oz/token/ERC20/extensions/IERC20Permit.sol";
import { ERC20Permit } from "@oz/token/ERC20/extensions/ERC20Permit.sol";
import { ECDSA } from "@oz/utils/cryptography/ECDSA.sol";
import { Math } from "@oz/utils/math/Math.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IRewardsVault } from "src/core/interfaces/IRewardsVault.sol";
import { IWithdrawalQueue } from "src/core/interfaces/IWithdrawalQueue.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { IStAztec } from "src/core/interfaces/IStAztec.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { IMockRewardsVault } from "src/core/mocks/IMockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/core/mocks/MockWithdrawalQueue.sol";
import { ISafetyModule } from "src/safetymodule/ISafetyModule.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";

contract OllaCoreHarness is OllaCore {
    /*//////////////////////////////////////////////////////////////
                           CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function exposedIncreaseBuffered(uint256 amount) external {
        _increaseBuffered(amount);
    }

    function exposedApplyAccountingUpdates(
        uint256 newStakedPrincipal,
        uint256 newRewardsVaultBalance,
        uint256 newClaimableRewards,
        uint256 newRewardsDelta,
        uint256 newSlashingDelta
    ) external {
        _applyAccountingUpdates(
            newStakedPrincipal, newRewardsVaultBalance, newClaimableRewards, newRewardsDelta, newSlashingDelta
        );
    }

    function exposedSyncBufferedWithBalance() external {
        _syncBufferedWithBalance();
    }

    function exposedComputeNetFlows(IOllaCore.FlowCounters memory flows)
        external
        pure
        returns (int256 netFlows, uint256 netDeposits, uint256 netWithdrawals)
    {
        return _computeNetFlows(flows);
    }

    function exposedComputeTotalAssets(IOllaCore.AccountingState memory buckets)
        external
        pure
        returns (uint256 totalAssets_)
    {
        return _computeTotalAssets(buckets);
    }

    function exposedComputeGrossRewards(uint256 oldTotalAssets, uint256 newTotalAssets, int256 netFlows)
        external
        pure
        returns (uint256 grossRewards)
    {
        return _computeGrossRewards(oldTotalAssets, newTotalAssets, netFlows);
    }

    function exposedCalculateProtocolFees(uint256 grossAssetRewards)
        external
        view
        returns (uint256 ollaProtocolFeeAssets, uint256 treasuryShares, uint256 providerShares)
    {
        return _calculateProtocolFees(grossAssetRewards);
    }
}

contract OllaCoreTest is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed caller, address indexed recipient, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed caller, address indexed recipient, address indexed owner, uint256 assets, uint256 shares
    );
    event Paused();
    event Unpaused();
    event Rebalanced(
        uint256 bufferedAssets, uint256 stakedPrincipal, uint256 rewardsVaultBalance, uint256 rewardsDelta
    );
    event AccountingUpdated(
        uint256 totalAssets,
        uint256 exchangeRate,
        uint256 grossRewards,
        int256 netFlows,
        uint256 protocolFeeAssets,
        uint256 treasuryShares,
        uint256 providerShares,
        uint256 timestamp
    );
    event AttestersStateRead(uint256 rewardsDelta, uint256 slashingDelta, uint256 timestamp);
    event WithdrawalFinalized(uint256 available, uint256 used);
    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed recipient,
        uint256 shares,
        uint256 assetsExpected,
        uint256 exchangeRate
    );
    event OllaProtocolFeesPaid(uint256 protocolFeeAssets, uint256 treasuryShares, uint256 providerShares);
    event RewardsDelta(uint256 delta);
    event BufferedAssetsReconciled(uint256 delta, uint256 newBufferedAssets, address indexed recipient);

    /*//////////////////////////////////////////////////////////////
                             CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCoreHarness internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    address internal governance;
    address internal alice;
    address internal bob;
    address internal permitOwner;
    uint256 internal permitOwnerKey;
    uint256 internal permitAttackerKey;
    MockWithdrawalQueue internal withdrawalQueue;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;
    address internal operator;
    address internal providerRewardsRecipient;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreHarness coreImplementation = new OllaCoreHarness();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCoreHarness(address(proxy));

        stakingManager = new MockAccountingStakingManager();
        governance = makeAddr("governance");
        stAztec = new StAztec(governance, address(vault));
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(coreImplementation));
        operator = makeAddr("operator");
        withdrawalQueue = new MockWithdrawalQueue();
        providerRewardsRecipient = makeAddr("providerRewardsRecipient");
        stakingManager.setProviderRewardsRecipient(providerRewardsRecipient);

        // Configure staking manager to mint rewards directly to rewards vault
        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsVault(address(rewardsVault));

        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            0,
            0,
            governance,
            address(withdrawalQueue),
            rewardsVault,
            address(safetyModule)
        );

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        permitOwnerKey = 0xA11CE;
        permitOwner = vm.addr(permitOwnerKey);
        permitAttackerKey = 0xB0B;

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.startPrank(governance);
        vault.grantRole(operatorRole, operator);
        vault.grantRole(operatorRole, address(this));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _performDeposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner);
        return shares;
    }

    function _queueRequestSnapshot()
        internal
        view
        returns (address user, uint256 shares, uint256 assetsExpected, uint256 rate)
    {
        (user,,, shares, assetsExpected, rate) = withdrawalQueue.lastRequest();
        return (user, shares, assetsExpected, rate);
    }

    function _signPermit(
        IERC20Permit token,
        address owner,
        uint256 ownerKey,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        uint256 nonce = token.nonces(owner);
        bytes32 digest = _buildPermitDigest(token, owner, spender, value, nonce, deadline);
        (v, r, s) = vm.sign(ownerKey, digest);
        return (v, r, s);
    }

    function _buildPermitDigest(
        IERC20Permit token,
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32 digest) {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        return digest;
    }

    /*//////////////////////////////////////////////////////////////
                          INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_InitializeSetsCoreAddresses() external view {
        assertEq(vault.asset(), address(asset), "asset set");
        assertEq(vault.stAztec(), address(stAztec), "stAztec set");
        assertEq(vault.stakingManager(), address(stakingManager), "staking manager set");
        assertEq(vault.governance(), governance, "governance set");
        assertEq(vault.withdrawalQueue(), address(withdrawalQueue), "withdrawal queue set");
        assertEq(vault.rewardsVault(), address(rewardsVault), "rewards vault set");
        assertEq(vault.safetyModule(), address(safetyModule), "safety module set");
        IOllaCore.LatestReport memory report = vault.latestReport();
        assertEq(report.exchangeRate, 1e18, "exchange rate init");
        assertEq(report.totalAssets, 0, "lastTotalAssets init");
    }

    function test_RevertWhen_Reinitialize() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            0,
            0,
            governance,
            address(withdrawalQueue),
            rewardsVault,
            address(safetyModule)
        );
    }

    /*//////////////////////////////////////////////////////////////
                           PAUSE CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_GuardianCanPauseAndUnpause() external {
        vm.expectEmit(true, true, true, true, address(vault));
        emit Paused();
        vm.prank(governance);
        vault.pause();

        vm.expectEmit(true, true, true, true, address(vault));
        emit Unpaused();
        vm.prank(governance);
        vault.unpause();
    }

    function test_RevertWhen_NonGuardianPause() external {
        vm.expectRevert();
        vm.prank(alice);
        vault.pause();
    }

    function test_RevertWhen_DepositWhilePaused() external {
        vm.prank(governance);
        vault.pause();

        asset.mint(alice, 5 * DECIMALS);
        vm.prank(alice);
        asset.approve(address(vault), 5 * DECIMALS);

        vm.expectRevert();
        vm.prank(alice);
        vault.deposit(5 * DECIMALS, alice);
    }

    /*//////////////////////////////////////////////////////////////
                         WITHDRAWAL REQUESTS
    //////////////////////////////////////////////////////////////*/

    function test_RequestRedeem_CallsQueueWithExpectedValues() external {
        _performDeposit(alice, 20 * DECIMALS);

        uint256 rate = vault.exchangeRate();
        uint256 shares = 6 * DECIMALS;
        uint256 expectedAssets = shares * rate / 1e18;

        vm.expectEmit(true, true, false, true, address(vault));
        emit WithdrawalRequested(1, bob, shares, expectedAssets, rate);

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, bob);

        assertEq(requestId, 1, "request id should start at 1");
        (address recipient, uint256 recordedShares, uint256 recordedAssets, uint256 recordedRate) =
            _queueRequestSnapshot();
        assertEq(recipient, bob, "queue receives recipient");
        assertEq(recordedShares, shares, "queue receives share amount");
        assertEq(recordedAssets, expectedAssets, "queue receives assetsExpected");
        assertEq(recordedRate, rate, "queue receives exchange rate");
    }

    /*//////////////////////////////////////////////////////////////
                      WITHDRAWAL REQUEST VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_ActiveRequestId_ReturnsZeroWhenNoRequest() external view {
        assertEq(vault.activeRequestId(alice), 0, "active request id is zero without request");
    }

    function test_RequestRedeem_SetsActiveRequestIdAndActiveRequest() external {
        _performDeposit(alice, 20 * DECIMALS);

        uint256 rate = vault.exchangeRate();
        uint256 shares = 7 * DECIMALS;
        uint256 expectedAssets = shares * rate / DECIMALS;

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, bob);

        assertEq(vault.activeRequestId(alice), requestId, "active request id matches request");

        IWithdrawalQueue.WithdrawalRequest memory request = vault.getActiveWithdrawalRequest(alice);
        assertEq(request.recipient, bob, "active request recipient matches");
        assertEq(request.shares, shares, "active request shares match");
        assertEq(request.assetsExpected, expectedAssets, "active request assets expected match");
        assertEq(request.rate, rate, "active request exchange rate matches");
        assertEq(request.finalized, false, "active request not finalized");
        assertEq(request.claimed, false, "active request not claimed");
    }

    function test_RequestOwner_ReturnsOwnerWhenRecipientDiffers() external {
        _performDeposit(alice, 12 * DECIMALS);

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(4 * DECIMALS, bob);

        assertEq(vault.requestOwner(requestId), alice, "request owner tracked separately from recipient");
    }

    /*//////////////////////////////////////////////////////////////
                          OPERATOR ACTIONS
    //////////////////////////////////////////////////////////////*/

    function test_OperatorCanCallOperatorHooks() external {
        vm.expectEmit(true, true, true, true, address(vault));
        emit Rebalanced(0, 0, 0, 0);
        vm.prank(operator);
        vault.rebalance();

        uint256 expectedExchangeRate = vault.exchangeRate();
        uint256 expectedTimestamp = block.timestamp;
        vm.expectEmit(true, true, true, true, address(vault));
        emit AttestersStateRead(0, 0, expectedTimestamp);
        vm.expectEmit(true, true, true, true, address(vault));
        emit AccountingUpdated(0, expectedExchangeRate, 0, 0, 0, 0, 0, expectedTimestamp);
        vm.prank(operator);
        vault.updateAccounting();
    }

    /*//////////////////////////////////////////////////////////////
                           WITHDRAWAL CLAIMS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimActiveRequest_ClearsActiveRequest() external {
        _performDeposit(alice, 20 * DECIMALS);

        uint256 rate = vault.exchangeRate();
        uint256 shares = 6 * DECIMALS;
        uint256 assetsExpected = shares * rate / 1e18;

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, alice);
        assertEq(requestId, 1, "request id starts at 1");

        uint256 balanceBefore = asset.balanceOf(alice);

        uint256 claimed = vault.claimActiveRequest(alice);

        uint256 balanceAfter = asset.balanceOf(alice);
        assertEq(claimed, assetsExpected, "claimed assets match expected");
        assertEq(balanceAfter - balanceBefore, assetsExpected, "assets transferred to recipient");

        vm.prank(alice);
        uint256 newRequestId = vault.requestRedeem(2 * DECIMALS, alice);
        assertEq(newRequestId, 2, "active request cleared after claim");
    }

    function test_ClaimRequestById_AllowsNonOwner() external {
        _performDeposit(alice, 15 * DECIMALS);

        uint256 rate = vault.exchangeRate();
        uint256 shares = 5 * DECIMALS;
        uint256 assetsExpected = shares * rate / 1e18;

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, bob);

        uint256 balanceBefore = asset.balanceOf(bob);

        vm.prank(bob);
        uint256 claimed = vault.claimRequestById(requestId);

        uint256 balanceAfter = asset.balanceOf(bob);
        assertEq(claimed, assetsExpected, "claimed assets match expected");
        assertEq(balanceAfter - balanceBefore, assetsExpected, "assets sent to receiver");

        vm.prank(alice);
        uint256 newRequestId = vault.requestRedeem(1 * DECIMALS, alice);
        assertEq(newRequestId, 2, "owner can request again after claim by id");
    }

    /*//////////////////////////////////////////////////////////////
                               DEPOSITS
    //////////////////////////////////////////////////////////////*/

    function test_DepositMintsAtExchangeRate() external {
        uint256 depositAssetAmountAlice = 100 * DECIMALS;
        uint256 firstShares = _performDeposit(alice, depositAssetAmountAlice);
        assertEq(firstShares, depositAssetAmountAlice, "first deposit: 1:1 shares at zero supply");

        vault.exposedApplyAccountingUpdates(0, 50 * DECIMALS, 0, 0, 0);

        uint256 totalAssetsBeforeSecondDeposit = vault.totalAssets();
        uint256 totalSharesBeforeSecondDeposit = stAztec.totalSupply();

        uint256 depositAssetAmountBob = 50 * DECIMALS;
        uint256 expectedShares = (depositAssetAmountBob)
        .mulDiv(totalSharesBeforeSecondDeposit, totalAssetsBeforeSecondDeposit, Math.Rounding.Floor);
        uint256 secondShares = _performDeposit(bob, depositAssetAmountBob);

        assertEq(secondShares, expectedShares, "second deposit: shares follow exchange rate");
    }

    function test_DepositsAreInstant() external {
        uint256 shares = _performDeposit(alice, 10 * DECIMALS);

        assertEq(stAztec.balanceOf(alice), shares, "shares minted");
        assertEq(vault.totalAssets(), 10 * DECIMALS, "assets buffered");
        IOllaCore.FlowCounters memory flows = vault.flowCounters();
        assertEq(flows.cumulativeDeposits, 10 * DECIMALS, "cumulative deposits updated");
    }

    /*//////////////////////////////////////////////////////////////
                           PERMIT DEPOSITS
    //////////////////////////////////////////////////////////////*/

    function test_DepositWithPermit_MintsAndClearsExactAllowance() external {
        uint256 assets = 10 * DECIMALS;
        asset.mint(permitOwner, assets);

        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(IERC20Permit(address(asset)), permitOwner, permitOwnerKey, address(vault), assets, deadline);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Deposit(permitOwner, permitOwner, assets, assets);

        vm.prank(permitOwner);
        uint256 shares = vault.depositWithPermit(assets, permitOwner, deadline, v, r, s);

        assertEq(shares, assets, "shares minted");
        assertEq(stAztec.balanceOf(permitOwner), assets, "shares balance");
        assertEq(asset.allowance(permitOwner, address(vault)), 0, "allowance consumed");
        assertEq(IERC20Permit(address(asset)).nonces(permitOwner), 1, "nonce incremented");
    }

    function test_DepositWithPermit_AllowsMaxAllowance() external {
        uint256 assets = type(uint256).max;
        asset.mint(permitOwner, assets);

        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(IERC20Permit(address(asset)), permitOwner, permitOwnerKey, address(vault), assets, deadline);

        vm.prank(permitOwner);
        uint256 shares = vault.depositWithPermit(assets, permitOwner, deadline, v, r, s);

        assertEq(shares, assets, "shares minted");
        assertEq(asset.allowance(permitOwner, address(vault)), type(uint256).max, "allowance remains max");
    }

    function test_RevertWhen_DepositWithPermit_ExpiredSignature() external {
        uint256 assets = 5 * DECIMALS;
        asset.mint(permitOwner, assets);

        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(IERC20Permit(address(asset)), permitOwner, permitOwnerKey, address(vault), assets, deadline);

        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        vm.prank(permitOwner);
        vault.depositWithPermit(assets, permitOwner, deadline, v, r, s);
    }

    function test_RevertWhen_DepositWithPermit_InvalidSignature() external {
        uint256 assets = 5 * DECIMALS;
        asset.mint(permitOwner, assets);

        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(IERC20Permit(address(asset)), permitOwner, permitAttackerKey, address(vault), assets, deadline);

        vm.expectRevert(
            abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, vm.addr(permitAttackerKey), permitOwner)
        );
        vm.prank(permitOwner);
        vault.depositWithPermit(assets, permitOwner, deadline, v, r, s);
    }

    function test_RevertWhen_DepositWithPermit_ReplayedNonce() external {
        uint256 assets = 6 * DECIMALS;
        asset.mint(permitOwner, assets * 2);

        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(IERC20Permit(address(asset)), permitOwner, permitOwnerKey, address(vault), assets, deadline);

        vm.prank(permitOwner);
        vault.depositWithPermit(assets, permitOwner, deadline, v, r, s);

        uint256 nonce = IERC20Permit(address(asset)).nonces(permitOwner);
        bytes32 digest =
            _buildPermitDigest(IERC20Permit(address(asset)), permitOwner, address(vault), assets, nonce, deadline);
        address signer = ECDSA.recover(digest, v, r, s);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, signer, permitOwner));
        vm.prank(permitOwner);
        vault.depositWithPermit(assets, permitOwner, deadline, v, r, s);
    }

    /*//////////////////////////////////////////////////////////////
                      PERMIT WITHDRAWAL REQUESTS
    //////////////////////////////////////////////////////////////*/

    function test_RequestRedeemWithPermit_CallsQueueAndEmits() external {
        _performDeposit(permitOwner, 20 * DECIMALS);

        uint256 shares = 6 * DECIMALS;
        uint256 rate = vault.exchangeRate();
        uint256 assetsExpected = shares * rate / DECIMALS;
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(IERC20Permit(address(stAztec)), permitOwner, permitOwnerKey, address(vault), shares, deadline);

        vm.expectEmit(true, true, false, true, address(vault));
        emit WithdrawalRequested(1, bob, shares, assetsExpected, rate);

        vm.prank(permitOwner);
        uint256 requestId = vault.requestRedeemWithPermit(shares, bob, deadline, v, r, s);

        assertEq(requestId, 1, "request id should start at 1");
        (address recipient, uint256 recordedShares, uint256 recordedAssets, uint256 recordedRate) =
            _queueRequestSnapshot();
        assertEq(recipient, bob, "queue receives recipient");
        assertEq(recordedShares, shares, "queue receives share amount");
        assertEq(recordedAssets, assetsExpected, "queue receives assetsExpected");
        assertEq(recordedRate, rate, "queue receives exchange rate");
        assertEq(stAztec.allowance(permitOwner, address(vault)), shares, "allowance set by permit");
        assertEq(IERC20Permit(address(stAztec)).nonces(permitOwner), 1, "nonce incremented");
    }

    function test_RequestRedeemWithPermit_AllowsMaxAllowance() external {
        uint256 assets = type(uint256).max;
        asset.mint(permitOwner, assets);
        uint256 deadline = block.timestamp + 1 days;
        (uint8 depositV, bytes32 depositR, bytes32 depositS) =
            _signPermit(IERC20Permit(address(asset)), permitOwner, permitOwnerKey, address(vault), assets, deadline);
        vm.prank(permitOwner);
        vault.depositWithPermit(assets, permitOwner, deadline, depositV, depositR, depositS);

        uint256 shares = type(uint256).max;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(IERC20Permit(address(stAztec)), permitOwner, permitOwnerKey, address(vault), shares, deadline);

        vm.prank(permitOwner);
        vault.requestRedeemWithPermit(shares, permitOwner, deadline, v, r, s);

        assertEq(stAztec.allowance(permitOwner, address(vault)), type(uint256).max, "allowance remains max");
    }

    function test_RevertWhen_RequestRedeemWithPermit_ExpiredSignature() external {
        _performDeposit(permitOwner, 20 * DECIMALS);

        uint256 shares = 4 * DECIMALS;
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(IERC20Permit(address(stAztec)), permitOwner, permitOwnerKey, address(vault), shares, deadline);

        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        vm.prank(permitOwner);
        vault.requestRedeemWithPermit(shares, permitOwner, deadline, v, r, s);
    }

    function test_RevertWhen_RequestRedeemWithPermit_InvalidSignature() external {
        _performDeposit(permitOwner, 20 * DECIMALS);

        uint256 shares = 4 * DECIMALS;
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            IERC20Permit(address(stAztec)), permitOwner, permitAttackerKey, address(vault), shares, deadline
        );

        vm.expectRevert(
            abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, vm.addr(permitAttackerKey), permitOwner)
        );
        vm.prank(permitOwner);
        vault.requestRedeemWithPermit(shares, permitOwner, deadline, v, r, s);
    }

    function test_RevertWhen_RequestRedeemWithPermit_ReplayedNonce() external {
        _performDeposit(permitOwner, 20 * DECIMALS);

        uint256 shares = 4 * DECIMALS;
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(IERC20Permit(address(stAztec)), permitOwner, permitOwnerKey, address(vault), shares, deadline);

        vm.prank(permitOwner);
        vault.requestRedeemWithPermit(shares, permitOwner, deadline, v, r, s);

        uint256 nonce = IERC20Permit(address(stAztec)).nonces(permitOwner);
        bytes32 digest =
            _buildPermitDigest(IERC20Permit(address(stAztec)), permitOwner, address(vault), shares, nonce, deadline);
        address signer = ECDSA.recover(digest, v, r, s);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, signer, permitOwner));
        vm.prank(permitOwner);
        vault.requestRedeemWithPermit(shares, permitOwner, deadline, v, r, s);
    }

    /*//////////////////////////////////////////////////////////////
                         NON-PERMIT FLOWS
    //////////////////////////////////////////////////////////////*/

    function test_Deposit_StillWorks() external {
        uint256 assets = 9 * DECIMALS;
        asset.mint(alice, assets);
        vm.prank(alice);
        asset.approve(address(vault), assets);

        vm.prank(alice);
        uint256 shares = vault.deposit(assets, alice);

        assertEq(shares, assets, "deposit shares");
        assertEq(stAztec.balanceOf(alice), assets, "shares minted");
    }

    function test_RequestRedeem_StillWorks() external {
        _performDeposit(alice, 15 * DECIMALS);

        uint256 shares = 5 * DECIMALS;
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, alice);

        assertEq(requestId, 1, "request id should start at 1");
    }

    /*//////////////////////////////////////////////////////////////
                          ACCOUNTING STATE
    //////////////////////////////////////////////////////////////*/

    function test_BucketGettersReflectState() external {
        uint256 assets = 10 * DECIMALS;
        uint256 staked = 6 * DECIMALS;
        uint256 rewardsVaultBalance = 4 * DECIMALS;
        uint256 claimableRewards = 3 * DECIMALS;
        uint256 rewardsDelta = 2 * DECIMALS;
        uint256 slashingDelta = 1 * DECIMALS;

        _performDeposit(alice, assets);
        vault.exposedApplyAccountingUpdates(staked, rewardsVaultBalance, claimableRewards, rewardsDelta, slashingDelta);

        IOllaCore.AccountingState memory accounting = vault.accountingState();
        assertEq(accounting.bufferedAssets, assets, "bufferedAssets matches deposited assets");
        assertEq(accounting.stakedPrincipal, staked, "stakedPrincipal matches staked amount");
        assertEq(accounting.rewardsVaultBalance, rewardsVaultBalance, "rewardsVaultBalance matches rewards vault");
        assertEq(accounting.claimableRewards, claimableRewards, "claimableRewards matches claimable rewards");
        assertEq(accounting.rewardsDelta, rewardsDelta, "rewardsDelta matches rewards delta");
        assertEq(accounting.slashingDelta, slashingDelta, "slashingDelta matches slashing delta");
        assertEq(
            vault.totalAssets(),
            assets + staked + rewardsVaultBalance + claimableRewards - slashingDelta,
            "totalAssets sums buckets"
        );
    }

    /*//////////////////////////////////////////////////////////////
                             FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_TotalAssetsComposition(
        uint96 buffered,
        uint96 staked,
        uint96 rewardsVaultBalance,
        uint96 claimableRewards,
        uint96 rewardsDelta,
        uint96 slashingDeltaSeed
    ) external {
        buffered = uint96(bound(buffered, 1, type(uint96).max));
        staked = uint96(bound(staked, 1, type(uint96).max));
        rewardsVaultBalance = uint96(bound(rewardsVaultBalance, 1, type(uint96).max));
        claimableRewards = uint96(bound(claimableRewards, 0, type(uint96).max));
        rewardsDelta = uint96(bound(rewardsDelta, 0, type(uint96).max));

        uint256 positiveTotal =
            uint256(buffered) + uint256(staked) + uint256(rewardsVaultBalance) + uint256(claimableRewards);
        uint256 slashingDelta = bound(uint256(slashingDeltaSeed), 0, positiveTotal);

        asset.mint(address(vault), buffered);
        vault.exposedIncreaseBuffered(buffered);
        vault.exposedApplyAccountingUpdates(staked, rewardsVaultBalance, claimableRewards, rewardsDelta, slashingDelta);

        assertEq(vault.totalAssets(), positiveTotal - slashingDelta, "totalAssets includes slashing delta");
    }

    function testFuzz_ComputeNetFlows(
        uint96 cumulativeDeposits,
        uint96 cumulativeWithdrawals,
        uint96 latestReportCumulativeDeposits,
        uint96 latestReportCumulativeWithdrawals
    ) external view {
        IOllaCore.FlowCounters memory flows = IOllaCore.FlowCounters({
            cumulativeDeposits: cumulativeDeposits,
            cumulativeWithdrawals: cumulativeWithdrawals,
            latestReportCumulativeDeposits: latestReportCumulativeDeposits,
            latestReportCumulativeWithdrawals: latestReportCumulativeWithdrawals
        });

        (int256 netFlows, uint256 netDeposits, uint256 netWithdrawals) = vault.exposedComputeNetFlows(flows);

        uint256 expectedNetDeposits = cumulativeDeposits > latestReportCumulativeDeposits
            ? cumulativeDeposits - latestReportCumulativeDeposits
            : 0;
        uint256 expectedNetWithdrawals = cumulativeWithdrawals > latestReportCumulativeWithdrawals
            ? cumulativeWithdrawals - latestReportCumulativeWithdrawals
            : 0;
        int256 expectedNetFlows = int256(expectedNetDeposits) - int256(expectedNetWithdrawals);

        assertEq(netDeposits, expectedNetDeposits, "net deposits fuzz");
        assertEq(netWithdrawals, expectedNetWithdrawals, "net withdrawals fuzz");
        assertEq(netFlows, expectedNetFlows, "net flows fuzz");
    }

    function testFuzz_ComputeGrossRewards(uint96 oldTotalAssets, uint96 newTotalAssets, int96 netFlows) external view {
        uint256 grossRewards = vault.exposedComputeGrossRewards(oldTotalAssets, newTotalAssets, netFlows);
        int256 changeInAssets = int256(uint256(newTotalAssets)) - int256(uint256(oldTotalAssets));
        int256 expectedGrossSigned = changeInAssets - int256(netFlows);
        uint256 expectedGross = expectedGrossSigned > 0 ? uint256(expectedGrossSigned) : 0;

        assertEq(grossRewards, expectedGross, "gross rewards fuzz");
    }

    /*//////////////////////////////////////////////////////////////
                         ACCOUNTING UPDATES
    //////////////////////////////////////////////////////////////*/

    function test_UpdateAccountingSnapshots() external {
        uint256 depositAmount = 25 * DECIMALS;

        _performDeposit(alice, depositAmount);

        IOllaCore.LatestReport memory reportBefore = vault.latestReport();
        IOllaCore.FlowCounters memory flowsBefore = vault.flowCounters();
        assertEq(reportBefore.totalAssets, 0, "lastTotalAssets before update");
        assertEq(flowsBefore.latestReportCumulativeDeposits, 0, "latestReportCumulativeDeposits before update");
        assertEq(flowsBefore.latestReportCumulativeWithdrawals, 0, "latestReportCumulativeWithdrawals before update");

        uint256 expectedRate = vault.exchangeRate();
        uint256 expectedTimestamp = block.timestamp;
        vm.expectEmit(true, true, true, true, address(vault));
        emit AttestersStateRead(0, 0, expectedTimestamp);
        vm.expectEmit(true, true, true, true, address(vault));
        emit AccountingUpdated(depositAmount, expectedRate, 0, int256(depositAmount), 0, 0, 0, expectedTimestamp);
        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = vault.latestReport();
        IOllaCore.FlowCounters memory flowsAfter = vault.flowCounters();
        assertEq(reportAfter.totalAssets, depositAmount, "lastTotalAssets updated");
        assertEq(reportAfter.exchangeRate, expectedRate, "stored exchange rate updated");
        assertEq(flowsAfter.latestReportCumulativeDeposits, depositAmount, "latestReportCumulativeDeposits updated");
        assertEq(flowsAfter.latestReportCumulativeWithdrawals, 0, "latestReportCumulativeWithdrawals updated");
        assertEq(flowsAfter.cumulativeDeposits, depositAmount, "cumulative deposits tracked");
        assertEq(reportAfter.exchangeRate, expectedRate, "latest report exchange rate stored");
        assertEq(reportAfter.timestamp, expectedTimestamp, "report timestamp updated");
    }

    function test_UpdateAccounting_NetFlowsNegative_ComputesGrossRewards() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.prank(operator);
        vault.updateAccounting();

        uint256 sharesToRedeem = 40 * DECIMALS;
        uint256 rate = vault.exchangeRate();
        uint256 assetsExpected = sharesToRedeem * rate / DECIMALS;
        vm.prank(alice);
        vault.requestRedeem(sharesToRedeem, alice);

        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = vault.latestReport();
        assertEq(reportAfter.netFlows, -int256(assetsExpected), "net flows negative");
        assertEq(reportAfter.grossRewards, assetsExpected, "gross rewards uses signed net flows");
        assertEq(reportAfter.totalAssets, depositAmount, "total assets unchanged");
    }

    function test_UpdateAccounting_GrossRewardsZero_TotalAssetsZero_NoFeeMinting() external {
        uint256 depositAmount = 12 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.prank(governance);
        vault.setProtocolFeeBP(1_000);

        stakingManager.setSlashingDelta(depositAmount);

        uint256 supplyBefore = stAztec.totalSupply();
        uint256 treasuryBalanceBefore = stAztec.balanceOf(governance);
        uint256 providerBalanceBefore = stAztec.balanceOf(providerRewardsRecipient);

        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = vault.latestReport();
        assertEq(reportAfter.grossRewards, 0, "gross rewards zero");
        assertEq(reportAfter.totalAssets, 0, "total assets zero");
        assertEq(reportAfter.exchangeRate, 0, "exchange rate zero");
        assertEq(stAztec.totalSupply(), supplyBefore, "no fee shares minted");
        assertEq(stAztec.balanceOf(governance), treasuryBalanceBefore, "treasury shares unchanged");
        assertEq(stAztec.balanceOf(providerRewardsRecipient), providerBalanceBefore, "provider shares unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                       ACCOUNTING CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    function test_ComputeNetFlows() external view {
        IOllaCore.FlowCounters memory flows = IOllaCore.FlowCounters({
            cumulativeDeposits: 12 * DECIMALS,
            cumulativeWithdrawals: 4 * DECIMALS,
            latestReportCumulativeDeposits: 5 * DECIMALS,
            latestReportCumulativeWithdrawals: 1 * DECIMALS
        });

        (int256 netFlows, uint256 netDeposits, uint256 netWithdrawals) = vault.exposedComputeNetFlows(flows);

        assertEq(netDeposits, 7 * DECIMALS, "net deposits");
        assertEq(netWithdrawals, 3 * DECIMALS, "net withdrawals");
        assertEq(netFlows, int256(4 * DECIMALS), "net flows");
    }

    function test_ComputeTotalAssets() external view {
        IOllaCore.AccountingState memory buckets = IOllaCore.AccountingState({
            bufferedAssets: 3 * DECIMALS,
            stakedPrincipal: 4 * DECIMALS,
            rewardsVaultBalance: 2 * DECIMALS,
            claimableRewards: 5 * DECIMALS,
            rewardsDelta: 1 * DECIMALS,
            slashingDelta: 5 * DECIMALS,
            cumulativeRewards: 0
        });

        uint256 totalAssets = vault.exposedComputeTotalAssets(buckets);

        assertEq(totalAssets, 9 * DECIMALS, "total assets computed");
    }

    function test_ComputeGrossRewards() external view {
        uint256 grossRewards = vault.exposedComputeGrossRewards(100 * DECIMALS, 130 * DECIMALS, int256(20 * DECIMALS));

        assertEq(grossRewards, 10 * DECIMALS, "gross rewards computed");
    }

    /*//////////////////////////////////////////////////////////////
                      ACCOUNTING TIMELINESS
    //////////////////////////////////////////////////////////////*/

    function test_UpdateAccountingTimestampMonotonic() external {
        _performDeposit(alice, 5 * DECIMALS);

        vm.prank(operator);
        vault.updateAccounting();
        IOllaCore.LatestReport memory firstReport = vault.latestReport();
        uint256 firstTimestamp = firstReport.timestamp;

        vm.warp(firstTimestamp + 1);
        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory secondReport = vault.latestReport();
        uint256 secondTimestamp = secondReport.timestamp;
        assertGt(secondTimestamp, firstTimestamp, "report timestamp should increase");
    }

    function test_UpdateAccountingIncludesRewardsAndSlashing() external {
        uint256 depositAmount = 20 * DECIMALS;
        uint256 harvestedRewards = 5 * DECIMALS;
        uint256 claimableRewards = 7 * DECIMALS;
        uint256 slashing = 2 * DECIMALS;
        uint256 stakedPrincipal = 11 * DECIMALS;

        _performDeposit(alice, depositAmount);
        stakingManager.setTotalStaked(stakedPrincipal);
        stakingManager.setHarvestedRewards(harvestedRewards);
        vm.prank(operator);
        vault.rebalance();
        stakingManager.setClaimableRewards(claimableRewards);
        stakingManager.setSlashingDelta(slashing);

        // rewardsDelta now comes from actual vault balance delta + claimable
        uint256 rewardsDelta = harvestedRewards + claimableRewards;
        uint256 expectedTotalAssets = depositAmount + stakedPrincipal + harvestedRewards + claimableRewards - slashing;
        uint256 expectedRate = expectedTotalAssets.mulDiv(DECIMALS, stAztec.totalSupply(), Math.Rounding.Floor);
        uint256 expectedGrossRewards = expectedTotalAssets > depositAmount ? expectedTotalAssets - depositAmount : 0;

        uint256 expectedTimestamp = block.timestamp;
        vm.expectEmit(true, true, true, true, address(vault));
        emit AttestersStateRead(rewardsDelta, slashing, expectedTimestamp);
        vm.expectEmit(true, true, true, true, address(vault));
        emit AccountingUpdated(
            expectedTotalAssets, expectedRate, expectedGrossRewards, int256(depositAmount), 0, 0, 0, expectedTimestamp
        );
        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = vault.latestReport();
        IOllaCore.FlowCounters memory flowsAfter = vault.flowCounters();
        assertEq(reportAfter.totalAssets, expectedTotalAssets, "lastTotalAssets updated");
        assertEq(reportAfter.exchangeRate, expectedRate, "stored exchange rate updated");
        assertEq(reportAfter.rewardsSnapshot, rewardsDelta, "rewards snapshot updated");
        assertEq(flowsAfter.latestReportCumulativeDeposits, depositAmount, "latestReportCumulativeDeposits updated");
        assertEq(flowsAfter.latestReportCumulativeWithdrawals, 0, "latestReportCumulativeWithdrawals updated");
    }

    function test_UpdateAccounting_RewardDeltaUsesCumulativeAndClaimableRewards() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        stakingManager.setHarvestedRewards(3 * DECIMALS);
        vm.prank(operator);
        vault.rebalance();
        stakingManager.setClaimableRewards(4 * DECIMALS);

        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory firstReport = vault.latestReport();
        assertEq(firstReport.rewardsSnapshot, 7 * DECIMALS, "first rewards snapshot stored");

        stakingManager.setHarvestedRewards(2 * DECIMALS);
        vm.prank(operator);
        vault.rebalance();
        stakingManager.setClaimableRewards(9 * DECIMALS);

        uint256 expectedDelta = 14 * DECIMALS - firstReport.rewardsSnapshot;
        uint256 expectedTimestamp = block.timestamp;
        vm.expectEmit(true, true, true, true, address(vault));
        emit AttestersStateRead(expectedDelta, 0, expectedTimestamp);
        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory secondReport = vault.latestReport();
        IOllaCore.AccountingState memory accounting = vault.accountingState();
        assertEq(accounting.rewardsDelta, expectedDelta, "rewards delta stored");
        assertEq(secondReport.rewardsSnapshot, 14 * DECIMALS, "rewards snapshot advanced");
    }

    function test_UpdateAccounting_RewardsDeltaClampsWhenClaimableDecreases() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        stakingManager.setClaimableRewards(10 * DECIMALS);
        vm.prank(operator);
        vault.updateAccounting();

        stakingManager.setClaimableRewards(5 * DECIMALS);
        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = vault.latestReport();
        IOllaCore.AccountingState memory accounting = vault.accountingState();
        assertEq(accounting.rewardsDelta, 0, "rewards delta clamps to zero");
        assertEq(reportAfter.rewardsSnapshot, 5 * DECIMALS, "rewards snapshot tracks current rewards");
    }

    function test_UpdateAccounting_ClaimableRewardsPersistWithoutHarvest() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 claimableRewards = 5 * DECIMALS;
        _performDeposit(alice, depositAmount);

        stakingManager.setClaimableRewards(claimableRewards);
        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.AccountingState memory accountingAfterFirst = vault.accountingState();
        assertEq(accountingAfterFirst.claimableRewards, claimableRewards, "claimable rewards stored");
        assertEq(vault.totalAssets(), depositAmount + claimableRewards, "total assets include claimable rewards");

        stakingManager.setClaimableRewards(claimableRewards);
        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.AccountingState memory accountingAfterSecond = vault.accountingState();
        IOllaCore.LatestReport memory reportAfterSecond = vault.latestReport();
        assertEq(accountingAfterSecond.claimableRewards, claimableRewards, "claimable rewards persist");
        assertEq(accountingAfterSecond.rewardsDelta, 0, "rewards delta resets to zero");
        assertEq(reportAfterSecond.rewardsSnapshot, claimableRewards, "rewards snapshot unchanged");
        assertEq(vault.totalAssets(), depositAmount + claimableRewards, "total assets remain stable");
    }

    function test_RevertWhen_UpdateAccountingSlashingDeltaDecreases() external {
        _performDeposit(alice, 5 * DECIMALS);

        stakingManager.setSlashingDelta(2 * DECIMALS);
        vm.prank(operator);
        vault.updateAccounting();

        stakingManager.setSlashingDelta(1 * DECIMALS);
        vm.expectRevert(
            abi.encodeWithSelector(IOllaCore.OllaCore__InvalidSlashingDelta.selector, 2 * DECIMALS, 1 * DECIMALS)
        );
        vm.prank(operator);
        vault.updateAccounting();
    }

    function test_UpdateAccounting_InvokesSafetyChecks() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 sharesToRedeem = 5 * DECIMALS;
        uint256 rate = vault.exchangeRate();
        uint256 assetsExpected = sharesToRedeem * rate / DECIMALS;
        vm.prank(alice);
        vault.requestRedeem(sharesToRedeem, alice);

        uint256 oldRate = 1e18;
        uint256 expectedRate = vault.exchangeRate();
        uint256 expectedTotalAssets = vault.totalAssets();
        vm.expectCall(address(safetyModule), abi.encodeCall(ISafetyModule.checkAccountingLiveness, ()));
        vm.expectCall(
            address(safetyModule), abi.encodeCall(ISafetyModule.checkQueueRatio, (assetsExpected, expectedTotalAssets))
        );
        vm.expectCall(address(safetyModule), abi.encodeCall(ISafetyModule.checkRateDrop, (oldRate, expectedRate)));
        vm.expectCall(
            address(safetyModule), abi.encodeCall(ISafetyModule.setLatestAccountingTimestamp, (block.timestamp))
        );

        vm.prank(operator);
        vault.updateAccounting();
    }

    /*//////////////////////////////////////////////////////////////
                             REBALANCE HARVEST
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_CallsRecordRewardsWithCorrectAmount() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 rewardAmount = 5 * DECIMALS;
        stakingManager.setHarvestedRewards(rewardAmount);

        uint256 totalReceivedBefore = rewardsVault.totalReceived();

        vm.prank(operator);
        vault.rebalance();

        uint256 totalReceivedAfter = rewardsVault.totalReceived();
        assertEq(
            totalReceivedAfter - totalReceivedBefore, rewardAmount, "recordBalance should be called with correct amount"
        );
    }

    function test_Rebalance_EmitsRewardsDeltaEvent() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 rewardAmount = 5 * DECIMALS;
        stakingManager.setHarvestedRewards(rewardAmount);

        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsDelta(rewardAmount);

        vm.prank(operator);
        vault.rebalance();
    }

    function test_Rebalance_EmitsRewardsDeltaEvent_WithZeroRewards() external {
        uint256 depositAmount = 10 * DECIMALS;
        _performDeposit(alice, depositAmount);

        // Set zero rewards
        stakingManager.setHarvestedRewards(0);

        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsDelta(0);

        vm.prank(operator);
        vault.rebalance();
    }

    /*//////////////////////////////////////////////////////////////
                             ERROR CASES
    //////////////////////////////////////////////////////////////*/

    function test_SyncBufferedWithBalance_ReconcilesExcessBalance() external {
        uint256 assets = 10 * DECIMALS;
        uint256 bonus = 2 * DECIMALS;

        _performDeposit(alice, assets);
        asset.mint(address(vault), bonus);

        vm.expectEmit(true, true, true, true, address(vault));
        emit BufferedAssetsReconciled(bonus, assets + bonus, address(vault));
        vault.exposedSyncBufferedWithBalance();

        IOllaCore.AccountingState memory accounting = vault.accountingState();
        assertEq(accounting.bufferedAssets, assets + bonus, "buffered assets reconciled");
    }

    function test_RevertWhen_BufferedBalanceBelowActual() external {
        uint256 assets = 5 * DECIMALS;

        vault.exposedIncreaseBuffered(assets);

        vm.expectRevert(abi.encodeWithSelector(OllaCore.OllaCore__BufferedBalanceMismatch.selector, assets, 0));
        vault.exposedSyncBufferedWithBalance();
    }

    function test_EmitDepositEvent() external {
        uint256 assets = 10 * DECIMALS;

        asset.mint(alice, assets);
        vm.prank(alice);
        asset.approve(address(vault), assets);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Deposit(alice, alice, assets, assets);

        vm.prank(alice);
        vault.deposit(assets, alice);
    }

    /*//////////////////////////////////////////////////////////////
                           INIT VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_InitializeZeroAddress() external {
        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        OllaCore newVault = OllaCore(address(proxy));
        MockAccountingStakingManager newStakingManager = new MockAccountingStakingManager();

        address newGovernance = makeAddr("governance");
        StAztec newStAztec = new StAztec(newGovernance, address(newVault));

        address newWithdrawalQueue = makeAddr("withdrawalQueue");
        MockRewardsVault newRewardsVault = new MockRewardsVault(asset, address(coreImplementation));
        address newSafetyModule = makeAddr("safetyModule");

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "asset_"));
        newVault.initialize(
            IERC20(address(0)),
            newStAztec,
            newStakingManager,
            0,
            0,
            newGovernance,
            newWithdrawalQueue,
            newRewardsVault,
            newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "stAztec_"));
        newVault.initialize(
            asset,
            IStAztec(address(0)),
            newStakingManager,
            0,
            0,
            newGovernance,
            newWithdrawalQueue,
            newRewardsVault,
            newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "stakingManager_"));
        newVault.initialize(
            asset,
            newStAztec,
            IStakingManager(address(0)),
            0,
            0,
            newGovernance,
            newWithdrawalQueue,
            newRewardsVault,
            newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "governance_"));
        newVault.initialize(
            asset, newStAztec, newStakingManager, 0, 0, address(0), newWithdrawalQueue, newRewardsVault, newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "withdrawalQueue_"));
        newVault.initialize(
            asset, newStAztec, newStakingManager, 0, 0, newGovernance, address(0), newRewardsVault, newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "rewardsVault_"));
        newVault.initialize(
            asset,
            newStAztec,
            newStakingManager,
            0,
            0,
            newGovernance,
            newWithdrawalQueue,
            IRewardsVault(address(0)),
            newSafetyModule
        );

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "safetyModule_"));
        newVault.initialize(
            asset, newStAztec, newStakingManager, 0, 0, newGovernance, newWithdrawalQueue, newRewardsVault, address(0)
        );
    }

    /*//////////////////////////////////////////////////////////////
                          FUZZED DEPOSITS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_DepositMintsShares(uint96 assets) external {
        assets = uint96(bound(assets, 1, type(uint96).max));

        uint256 shares = _performDeposit(alice, assets);

        assertEq(shares, assets, "shares minted at 1:1");
        assertEq(stAztec.balanceOf(alice), shares, "shares balance");
        assertEq(vault.totalAssets(), assets, "assets buffered");
    }
}

contract OllaCoreRewardsAccessControlTest is Test {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event ProtocolFeeUpdated(uint256 oldFeeBP, uint256 newFeeBP);
    event TreasuryFeeSplitUpdated(uint256 oldSplitBP, uint256 newSplitBP);
    event GovernanceUpdated(address oldGovernance, address newGovernance);
    event RewardsVaultUpdated(address oldRewardsVault, address newRewardsVault);
    event TargetBufferUpdated(uint256 oldBuffer, uint256 newBuffer);

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant BP_DIVISOR = 10_000;
    uint256 internal constant INITIAL_PROTOCOL_FEE_BP = 500;
    uint256 internal constant INITIAL_TREASURY_SPLIT_BP = 5_000;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCore internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    address internal governance;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;
    MockWithdrawalQueue internal withdrawalQueue;
    address internal alice;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCore(address(proxy));

        governance = makeAddr("governance");
        stAztec = new StAztec(governance, address(vault));
        stakingManager = new MockStakingManager();
        rewardsVault = new MockRewardsVault(asset, address(coreImplementation));
        safetyModule = new MockSafetyModule(address(coreImplementation));
        withdrawalQueue = new MockWithdrawalQueue();

        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            INITIAL_PROTOCOL_FEE_BP,
            INITIAL_TREASURY_SPLIT_BP,
            governance,
            address(withdrawalQueue),
            rewardsVault,
            address(safetyModule)
        );

        alice = makeAddr("alice");
    }

    /*//////////////////////////////////////////////////////////////
                         ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_NonAdminSetsProtocolFeeBP() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        vault.setProtocolFeeBP(100);
    }

    function test_RevertWhen_NonAdminSetsTreasuryFeeSplitBP() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        vault.setTreasuryFeeSplitBP(100);
    }

    function test_RevertWhen_NonAdminSetsGovernance() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        vault.setGovernance(alice);
    }

    function test_RevertWhen_NonAdminSetsRewardsVault() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        vault.setRewardsVault(IRewardsVault(alice));
    }

    function test_RevertWhen_NonAdminSetsTargetBuffer() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, vault.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        vault.setTargetBuffer(1);
    }

    /*//////////////////////////////////////////////////////////////
                        INVALID VALUE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ProtocolFeeBPExceedsMax() external {
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidFeeBP.selector, BP_DIVISOR + 1));
        vm.prank(governance);
        vault.setProtocolFeeBP(BP_DIVISOR + 1);
    }

    function test_RevertWhen_TreasuryFeeSplitBPExceedsMax() external {
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidSplitBP.selector, BP_DIVISOR + 1));
        vm.prank(governance);
        vault.setTreasuryFeeSplitBP(BP_DIVISOR + 1);
    }

    function test_RevertWhen_GovernanceIsZero() external {
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "newGovernance"));
        vm.prank(governance);
        vault.setGovernance(address(0));
    }

    function test_RevertWhen_RewardsVaultIsZero() external {
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__ZeroAddress.selector, "newRewardsVault"));
        vm.prank(governance);
        vault.setRewardsVault(IRewardsVault(address(0)));
    }

    function test_RevertWhen_TargetBufferIsZero() external {
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidTargetBuffer.selector, 0));
        vm.prank(governance);
        vault.setTargetBuffer(0);
    }

    /*//////////////////////////////////////////////////////////////
                        SUCCESSFUL UPDATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetProtocolFeeBP_UpdatesAndEmits() external {
        uint256 oldFeeBP = vault.protocolFeeBP();
        uint256 newFeeBP = 1000;

        vm.expectEmit(true, true, true, true, address(vault));
        emit ProtocolFeeUpdated(oldFeeBP, newFeeBP);

        vm.prank(governance);
        vault.setProtocolFeeBP(newFeeBP);

        assertEq(vault.protocolFeeBP(), newFeeBP, "protocol fee updated");
    }

    function test_SetTreasuryFeeSplitBP_UpdatesAndEmits() external {
        uint256 oldSplitBP = vault.treasuryFeeSplitBP();
        uint256 newSplitBP = 7_000;

        vm.expectEmit(true, true, true, true, address(vault));
        emit TreasuryFeeSplitUpdated(oldSplitBP, newSplitBP);

        vm.prank(governance);
        vault.setTreasuryFeeSplitBP(newSplitBP);

        assertEq(vault.treasuryFeeSplitBP(), newSplitBP, "treasury split updated");
    }

    function test_SetGovernance_UpdatesAndEmits() external {
        address newGovernance = makeAddr("newGovernance");

        vm.prank(governance);
        vault.setGovernance(newGovernance);

        assertEq(vault.governance(), newGovernance, "governance updated");
    }

    function test_SetRewardsVault_UpdatesAndEmits() external {
        address oldRewardsVault = vault.rewardsVault();
        address newRewardsVault = makeAddr("newRewardsVault");

        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsVaultUpdated(oldRewardsVault, newRewardsVault);

        vm.prank(governance);
        vault.setRewardsVault(IRewardsVault(newRewardsVault));

        assertEq(vault.rewardsVault(), newRewardsVault, "rewards vault updated");
    }

    function test_SetTargetBuffer_UpdatesAndEmits() external {
        uint256 oldBuffer = vault.targetBuffer();
        uint256 newBuffer = oldBuffer + 1;

        vm.expectEmit(true, true, true, true, address(vault));
        emit TargetBufferUpdated(oldBuffer, newBuffer);

        vm.prank(governance);
        vault.setTargetBuffer(newBuffer);

        assertEq(vault.targetBuffer(), newBuffer, "target buffer updated");
    }

    /*//////////////////////////////////////////////////////////////
                           BOUNDARY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetProtocolFeeBP_AllowsZero() external {
        vm.prank(governance);
        vault.setProtocolFeeBP(0);
        assertEq(vault.protocolFeeBP(), 0, "protocol fee set to zero");
    }

    function test_SetProtocolFeeBP_AllowsMax() external {
        vm.prank(governance);
        vault.setProtocolFeeBP(BP_DIVISOR);
        assertEq(vault.protocolFeeBP(), BP_DIVISOR, "protocol fee set to max");
    }

    function test_SetTreasuryFeeSplitBP_AllowsZero() external {
        vm.prank(governance);
        vault.setTreasuryFeeSplitBP(0);
        assertEq(vault.treasuryFeeSplitBP(), 0, "treasury split set to zero");
    }

    function test_SetTreasuryFeeSplitBP_AllowsMax() external {
        vm.prank(governance);
        vault.setTreasuryFeeSplitBP(BP_DIVISOR);
        assertEq(vault.treasuryFeeSplitBP(), BP_DIVISOR, "treasury split set to max");
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SetProtocolFeeBP_ValidRange(uint256 newFeeBP) external {
        newFeeBP = bound(newFeeBP, 0, BP_DIVISOR);

        uint256 oldFeeBP = vault.protocolFeeBP();

        vm.expectEmit(true, true, true, true, address(vault));
        emit ProtocolFeeUpdated(oldFeeBP, newFeeBP);

        vm.prank(governance);
        vault.setProtocolFeeBP(newFeeBP);

        assertEq(vault.protocolFeeBP(), newFeeBP, "protocol fee fuzz");
    }

    function testFuzz_SetProtocolFeeBP_InvalidRange(uint256 newFeeBP) external {
        newFeeBP = bound(newFeeBP, BP_DIVISOR + 1, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidFeeBP.selector, newFeeBP));
        vm.prank(governance);
        vault.setProtocolFeeBP(newFeeBP);
    }

    function testFuzz_SetTreasuryFeeSplitBP_ValidRange(uint256 newSplitBP) external {
        newSplitBP = bound(newSplitBP, 0, BP_DIVISOR);

        uint256 oldSplitBP = vault.treasuryFeeSplitBP();

        vm.expectEmit(true, true, true, true, address(vault));
        emit TreasuryFeeSplitUpdated(oldSplitBP, newSplitBP);

        vm.prank(governance);
        vault.setTreasuryFeeSplitBP(newSplitBP);

        assertEq(vault.treasuryFeeSplitBP(), newSplitBP, "treasury split fuzz");
    }

    function testFuzz_SetTreasuryFeeSplitBP_InvalidRange(uint256 newSplitBP) external {
        newSplitBP = bound(newSplitBP, BP_DIVISOR + 1, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__InvalidSplitBP.selector, newSplitBP));
        vm.prank(governance);
        vault.setTreasuryFeeSplitBP(newSplitBP);
    }

    function testFuzz_SetGovernance_NonZeroAddress(address newGovernance) external {
        vm.assume(newGovernance != address(0));

        vm.prank(governance);
        vault.setGovernance(newGovernance);

        assertEq(vault.governance(), newGovernance, "governance fuzz");
    }

    function testFuzz_SetRewardsVault_NonZeroAddress(address newRewardsVault) external {
        vm.assume(newRewardsVault != address(0));

        address oldRewardsVault = vault.rewardsVault();

        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsVaultUpdated(oldRewardsVault, newRewardsVault);

        vm.prank(governance);
        vault.setRewardsVault(IRewardsVault(newRewardsVault));

        assertEq(vault.rewardsVault(), newRewardsVault, "rewards vault fuzz");
    }
}

contract OllaCoreProtocolFeesTest is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event AccountingUpdated(
        uint256 totalAssets,
        uint256 exchangeRate,
        uint256 grossRewards,
        int256 netFlows,
        uint256 protocolFeeAssets,
        uint256 treasuryShares,
        uint256 providerShares,
        uint256 timestamp
    );
    event AttestersStateRead(uint256 rewardsDelta, uint256 slashingDelta, uint256 timestamp);
    event OllaProtocolFeesPaid(uint256 protocolFeeAssets, uint256 treasuryShares, uint256 providerShares);

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant PROTOCOL_FEE_BP = 500;
    uint256 internal constant TREASURY_FEE_SPLIT_BP = 5_000;
    uint256 internal constant BP_DIVISOR = 10_000;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCoreHarness internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    address internal governance;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;
    MockWithdrawalQueue internal withdrawalQueue;
    address internal operator;
    address internal alice;
    address internal providerRewardsRecipient;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreHarness coreImplementation = new OllaCoreHarness();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCoreHarness(address(proxy));

        governance = makeAddr("governance");
        stAztec = new StAztec(governance, address(vault));
        stakingManager = new MockAccountingStakingManager();
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(coreImplementation));
        operator = makeAddr("operator");
        withdrawalQueue = new MockWithdrawalQueue();
        providerRewardsRecipient = makeAddr("providerRewardsRecipient");
        stakingManager.setProviderRewardsRecipient(providerRewardsRecipient);

        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            PROTOCOL_FEE_BP,
            TREASURY_FEE_SPLIT_BP,
            governance,
            address(withdrawalQueue),
            IRewardsVault(address(rewardsVault)),
            address(safetyModule)
        );

        alice = makeAddr("alice");

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.startPrank(governance);
        vault.grantRole(operatorRole, operator);
        vault.grantRole(operatorRole, address(this));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _performDeposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner);
        return shares;
    }

    /*//////////////////////////////////////////////////////////////
                                TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CalculateProtocolFees_NonZeroAssets_MatchesConvertToShares() external {
        uint256 depositAmount = 50 * DECIMALS;
        _performDeposit(alice, depositAmount);

        uint256 grossRewards = 100 * DECIMALS;

        assertGt(stAztec.totalSupply(), 0, "supply nonzero");
        assertGt(vault.totalAssets(), 0, "total assets nonzero");

        (uint256 feeAssets, uint256 treasuryShares, uint256 providerShares) =
            vault.exposedCalculateProtocolFees(grossRewards);

        uint256 expectedFeeAssets = grossRewards * PROTOCOL_FEE_BP / BP_DIVISOR;
        uint256 expectedSharesTotal = vault.convertToShares(expectedFeeAssets);

        assertEq(feeAssets, expectedFeeAssets, "fee assets");
        assertEq(treasuryShares + providerShares, expectedSharesTotal, "fee shares match convertToShares");
    }

    function test_CalculateProtocolFees_LargeAssetsTinyRewards_MatchesConvertToShares() external {
        uint256 depositAmount = 1e24;
        _performDeposit(alice, depositAmount);
        vault.exposedApplyAccountingUpdates(1, 0, 0, 0, 0);

        uint256 grossRewards = 20;
        (uint256 feeAssets, uint256 treasuryShares, uint256 providerShares) =
            vault.exposedCalculateProtocolFees(grossRewards);

        uint256 expectedFeeAssets = grossRewards * PROTOCOL_FEE_BP / BP_DIVISOR;
        uint256 expectedSharesTotal = vault.convertToShares(expectedFeeAssets);
        uint256 supply = stAztec.totalSupply();
        uint256 totalAssets = vault.totalAssets();

        assertEq(feeAssets, expectedFeeAssets, "fee assets");
        assertEq(supply, depositAmount, "supply from deposit");
        assertEq(totalAssets, depositAmount + 1, "total assets updated");
        assertEq(treasuryShares + providerShares, expectedSharesTotal, "fee shares match convertToShares");
        assertEq(
            expectedSharesTotal, expectedFeeAssets.mulDiv(supply, totalAssets, Math.Rounding.Floor), "shares floor"
        );
        assertEq(expectedSharesTotal, 0, "tiny fee rounds down");
    }

    function test_UpdateAccounting_PaysProtocolFeesAndMintsSplitShares() external {
        uint256 depositAmount = 100 * DECIMALS;
        uint256 rewards = 20 * DECIMALS;

        uint256 sharesMinted = _performDeposit(alice, depositAmount);
        assertEq(sharesMinted, depositAmount, "deposit mints 1:1 at zero supply");

        stakingManager.setClaimableRewards(rewards);

        uint256 oldSupply = stAztec.totalSupply();
        uint256 oldGovShares = stAztec.balanceOf(governance);
        uint256 oldProviderShares = stAztec.balanceOf(providerRewardsRecipient);

        uint256 expectedTotalAssets = depositAmount + rewards;
        uint256 grossRewards = rewards;
        uint256 protocolFeeAssets = grossRewards * PROTOCOL_FEE_BP / BP_DIVISOR;

        uint256 rateBeforeRewards = expectedTotalAssets.mulDiv(DECIMALS, oldSupply, Math.Rounding.Floor);
        uint256 protocolSharesTotal = protocolFeeAssets.mulDiv(DECIMALS, rateBeforeRewards, Math.Rounding.Floor);
        uint256 treasuryShares = protocolSharesTotal * TREASURY_FEE_SPLIT_BP / BP_DIVISOR;
        uint256 providerShares = protocolSharesTotal - treasuryShares;

        uint256 expectedRateAfter =
            expectedTotalAssets.mulDiv(DECIMALS, oldSupply + protocolSharesTotal, Math.Rounding.Floor);
        uint256 expectedTimestamp = block.timestamp;

        vm.expectEmit(true, true, true, true, address(vault));
        emit OllaProtocolFeesPaid(protocolFeeAssets, treasuryShares, providerShares);
        vm.expectEmit(true, true, true, true, address(vault));
        emit AttestersStateRead(rewards, 0, expectedTimestamp);
        vm.expectEmit(true, true, true, true, address(vault));
        emit AccountingUpdated(
            expectedTotalAssets,
            expectedRateAfter,
            grossRewards,
            int256(depositAmount),
            protocolFeeAssets,
            treasuryShares,
            providerShares,
            expectedTimestamp
        );

        vm.prank(operator);
        vault.updateAccounting();

        assertEq(stAztec.totalSupply(), oldSupply + protocolSharesTotal, "protocol fee shares minted");
        assertEq(stAztec.balanceOf(governance), oldGovShares + treasuryShares, "treasury shares minted");
        assertEq(
            stAztec.balanceOf(providerRewardsRecipient), oldProviderShares + providerShares, "provider shares minted"
        );
    }

    function test_UpdateAccounting_ProtocolFeeSplitRoundsDownTreasuryAndKeepsRemainder() external {
        uint256 depositAmount = 100 * DECIMALS;

        _performDeposit(alice, depositAmount);

        // Pick rewards that are very likely to produce a fractional share result,
        // so floor rounding differs from ceil and leaves a remainder to the provider split.
        uint256 rewards = 1 * DECIMALS + 1;
        stakingManager.setClaimableRewards(rewards);

        uint256 oldSupply = stAztec.totalSupply();

        uint256 expectedTotalAssets = depositAmount + rewards;
        uint256 protocolFeeAssets = rewards * PROTOCOL_FEE_BP / BP_DIVISOR;
        uint256 rateBeforeRewards = expectedTotalAssets.mulDiv(DECIMALS, oldSupply, Math.Rounding.Floor);
        uint256 protocolSharesTotal = protocolFeeAssets.mulDiv(DECIMALS, rateBeforeRewards, Math.Rounding.Floor);
        uint256 protocolSharesCeil = protocolFeeAssets.mulDiv(DECIMALS, rateBeforeRewards, Math.Rounding.Ceil);

        uint256 treasuryShares = protocolSharesTotal * TREASURY_FEE_SPLIT_BP / BP_DIVISOR;
        uint256 providerShares = protocolSharesTotal - treasuryShares;

        assertLt(protocolSharesTotal, protocolSharesCeil, "floor rounding applied");
        // Invariant: split adds up exactly, and provider keeps any remainder from floor split.
        assertEq(treasuryShares + providerShares, protocolSharesTotal, "split sums to total");
        assertLe(treasuryShares, providerShares + 1, "treasury floor split at 50/50");

        vm.prank(operator);
        vault.updateAccounting();

        assertEq(stAztec.balanceOf(governance), treasuryShares, "treasury minted (from zero)");
        assertEq(stAztec.balanceOf(providerRewardsRecipient), providerShares, "provider minted (from zero)");
    }

    function test_UpdateAccounting_NetFlowsNegative_MintsFeesFromGrossRewards() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.prank(operator);
        vault.updateAccounting();

        uint256 sharesToRedeem = 40 * DECIMALS;
        uint256 rate = vault.exchangeRate();
        uint256 assetsExpected = sharesToRedeem * rate / DECIMALS;
        vm.prank(alice);
        vault.requestRedeem(sharesToRedeem, alice);

        uint256 oldSupply = stAztec.totalSupply();
        uint256 oldGovShares = stAztec.balanceOf(governance);
        uint256 oldProviderShares = stAztec.balanceOf(providerRewardsRecipient);

        uint256 expectedTotalAssets = depositAmount;
        uint256 grossRewards = assetsExpected;
        uint256 protocolFeeAssets = grossRewards * PROTOCOL_FEE_BP / BP_DIVISOR;
        uint256 rateBeforeFees = expectedTotalAssets.mulDiv(DECIMALS, oldSupply, Math.Rounding.Floor);
        uint256 protocolSharesTotal = protocolFeeAssets.mulDiv(DECIMALS, rateBeforeFees, Math.Rounding.Floor);
        uint256 treasuryShares = protocolSharesTotal * TREASURY_FEE_SPLIT_BP / BP_DIVISOR;
        uint256 providerShares = protocolSharesTotal - treasuryShares;

        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = vault.latestReport();
        assertEq(reportAfter.netFlows, -int256(assetsExpected), "net flows negative");
        assertEq(reportAfter.grossRewards, grossRewards, "gross rewards includes negative net flows");
        assertEq(stAztec.totalSupply(), oldSupply + protocolSharesTotal, "protocol fee shares minted");
        assertEq(stAztec.balanceOf(governance), oldGovShares + treasuryShares, "treasury shares minted");
        assertEq(
            stAztec.balanceOf(providerRewardsRecipient), oldProviderShares + providerShares, "provider shares minted"
        );
    }

    function test_UpdateAccounting_GrossRewardsClamp_NoFeeMinting() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.prank(operator);
        vault.updateAccounting();

        uint256 extraDeposit = 10 * DECIMALS;
        _performDeposit(alice, extraDeposit);
        stakingManager.setSlashingDelta(30 * DECIMALS);

        uint256 oldSupply = stAztec.totalSupply();
        uint256 oldGovShares = stAztec.balanceOf(governance);
        uint256 oldProviderShares = stAztec.balanceOf(providerRewardsRecipient);

        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = vault.latestReport();
        assertEq(reportAfter.grossRewards, 0, "gross rewards clamped to zero");
        assertEq(reportAfter.netFlows, int256(extraDeposit), "net flows positive");
        assertEq(stAztec.totalSupply(), oldSupply, "no fee shares minted");
        assertEq(stAztec.balanceOf(governance), oldGovShares, "no treasury shares minted");
        assertEq(stAztec.balanceOf(providerRewardsRecipient), oldProviderShares, "no provider shares minted");
    }

    function test_UpdateAccounting_GrossRewardsZero_TotalAssetsZero_NoFeeMinting() external {
        uint256 depositAmount = 100 * DECIMALS;
        _performDeposit(alice, depositAmount);

        vm.prank(operator);
        vault.updateAccounting();

        stakingManager.setSlashingDelta(depositAmount);

        uint256 oldSupply = stAztec.totalSupply();
        uint256 oldGovShares = stAztec.balanceOf(governance);
        uint256 oldProviderShares = stAztec.balanceOf(providerRewardsRecipient);

        vm.prank(operator);
        vault.updateAccounting();

        IOllaCore.LatestReport memory reportAfter = vault.latestReport();
        assertEq(reportAfter.grossRewards, 0, "gross rewards zero");
        assertEq(reportAfter.totalAssets, 0, "report total assets zero");
        assertEq(reportAfter.exchangeRate, 0, "exchange rate zero");
        assertEq(vault.totalAssets(), 0, "total assets zeroed");
        assertEq(stAztec.totalSupply(), oldSupply, "no fee shares minted");
        assertEq(stAztec.balanceOf(governance), oldGovShares, "no treasury shares minted");
        assertEq(stAztec.balanceOf(providerRewardsRecipient), oldProviderShares, "no provider shares minted");
        assertGt(stAztec.totalSupply(), 0, "supply remains positive");
    }

    /// @notice Reproduces rounding error from invariant test failure.
    /// The contract's convertToAssets uses two mulDiv operations (via exchangeRate),
    /// while the spec expects a single mulDiv: shares * totalAssets / totalSupply.
    /// This causes a 1 wei difference at large values.
    function test_ConvertToAssets_RoundingError_ReproducesInvariantFailure() external {
        // Reproduce the exact shrunk sequence from the failing invariant test:
        // 1. setTotalStaked(10135855071863320976892102731)
        // 2. updateAccounting()
        // 3. deposit(3, 0)

        // Step 1: Set a large totalStaked value
        uint256 largeStaked = 10135855071863320976892102731;
        stakingManager.setTotalStaked(largeStaked);

        // Step 2: Update accounting to apply the staked principal
        vm.prank(operator);
        vault.updateAccounting();

        // Step 3: Small deposit to create shares
        uint256 depositAmount = 3;
        _performDeposit(alice, depositAmount);

        // Now check the invariant: convertToAssets should match the spec
        uint256 supply = stAztec.totalSupply();
        uint256 total = vault.totalAssets();

        // Use a shares value that triggers the rounding difference
        // The invariant test uses block.number bounded to [1, type(uint96).max]
        uint256 shares = supply; // Use total supply as test shares

        // Contract's implementation (two-step via exchange rate)
        uint256 contractResult = vault.convertToAssets(shares);

        // Spec's expected result (single-step direct calculation)
        uint256 expectedResult = shares.mulDiv(total, supply, Math.Rounding.Floor);

        // This assertion will fail, demonstrating the rounding error
        assertEq(contractResult, expectedResult, "convertToAssets matches spec");
    }
}
