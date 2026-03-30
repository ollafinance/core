// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IWithdrawalQueue } from "src/vault/interfaces/IWithdrawalQueue.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { WithdrawalQueue } from "src/vault/WithdrawalQueue.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

/// @title WithdrawalQueueClaimDirectTest
/// @notice Verifies the S-1 fix: direct claimWithdrawal calls from non-vault addresses must revert.
/// @dev Uses a real OllaCore and real WithdrawalQueue (both behind UUPS proxies) so the
///      onlyVault modifier is exercised end-to-end.
contract WithdrawalQueueClaimDirectTest is Test {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    WithdrawalQueue internal withdrawalQueue;
    MockAccountingStakingManager internal stakingManager;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;

    address internal governance;
    address internal operator;
    address internal alice;
    address internal providerRewardsRecipient;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));
        governance = makeAddr("governance");
        operator = makeAddr("operator");
        alice = makeAddr("alice");
        providerRewardsRecipient = makeAddr("providerRewardsRecipient");

        // Deploy OllaCore behind a UUPS proxy
        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        // Deploy OllaVault behind a UUPS proxy
        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        // Deploy supporting modules
        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));
        stakingManager = new MockAccountingStakingManager();
        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));
        stakingManager.setProviderRewardsRecipient(providerRewardsRecipient);

        // Deploy WithdrawalQueue behind a UUPS proxy
        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImplementation), "");
        withdrawalQueue = WithdrawalQueue(address(queueProxy));

        // Initialize WithdrawalQueue with OllaVault as the authorized vault address
        // (must happen before vault.initialize which calls setGasThreshold on WQ)
        withdrawalQueue.initialize(address(vault), governance, 180_000);

        // Initialize OllaCore
        core.initialize(
            asset,
            stAztec,
            stakingManager,
            0, // protocolFeeBP
            5_000, // treasuryFeeSplitBP
            governance,
            rewardsAccumulator,
            address(safetyModule)
        );

        // Initialize OllaVault
        vault.initialize(asset, stAztec, address(withdrawalQueue), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits assets into OllaVault on behalf of a user.
    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        asset.mint(user, assets);
        vm.prank(user);
        asset.approve(address(vault), assets);
        vm.prank(user);
        shares = vault.deposit(assets, user, 0);
        return shares;
    }

    /// @notice Creates a withdrawal request and finalizes it via rebalance.
    /// @return requestId The finalized withdrawal request id.
    function _createAndFinalizeRequest(address user, uint256 depositAmount, uint256 redeemShares)
        internal
        returns (uint256 requestId)
    {
        // Deposit assets to get shares
        _deposit(user, depositAmount);

        // Request redemption
        vm.prank(user);
        requestId = vault.requestRedeem(redeemShares, user, user);

        // Advance past the 1-hour rebalance cooldown initialised in OllaCore.initialize()
        vm.warp(block.timestamp + 1 hours);

        // Rebalance to finalize the withdrawal (the queue has pending assets and core has buffer)
        vm.prank(operator);
        core.rebalance();

        // Verify the request is finalized
        IWithdrawalQueue.WithdrawalRequest memory request = withdrawalQueue.getRequest(requestId);
        assertTrue(request.finalized, "request should be finalized after rebalance");

        return requestId;
    }

    /*//////////////////////////////////////////////////////////////
                    DIRECT CLAIM ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice A non-vault address calling claimWithdrawal directly on WithdrawalQueue must revert.
    function test_RevertWhen_ClaimWithdrawal_DirectCallFromNonVault() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 redeemShares = 5 * DECIMALS;

        // Create and finalize a request via the core flow
        uint256 requestId = _createAndFinalizeRequest(alice, depositAmount, redeemShares);

        // Alice (not vault) calls claimWithdrawal directly on the queue -- must revert
        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__UnauthorizedVault.selector, alice));
        vm.prank(alice);
        withdrawalQueue.claimWithdrawal(requestId);
    }

    /// @notice Claiming through OllaVault.claimRequestById succeeds because OllaVault is the
    ///         authorized vault address on the WithdrawalQueue.
    function test_ClaimWithdrawal_SucceedsFromVault() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 redeemShares = 5 * DECIMALS;

        // Create and finalize a request via the core flow
        uint256 requestId = _createAndFinalizeRequest(alice, depositAmount, redeemShares);

        // Snapshot alice's balance before claim
        uint256 balanceBefore = asset.balanceOf(alice);

        // Compute the expected assets for the request
        IWithdrawalQueue.WithdrawalRequest memory request = withdrawalQueue.getRequest(requestId);
        uint256 expectedAssets = request.assetsExpected;

        // Claim via OllaVault (which is the authorized vault on the queue)
        vm.prank(alice);
        uint256 claimed = vault.claimRequestById(requestId);

        // Verify correct amount was claimed and transferred
        uint256 balanceAfter = asset.balanceOf(alice);
        assertEq(claimed, expectedAssets, "claimed assets should match expected");
        assertEq(balanceAfter - balanceBefore, expectedAssets, "alice should receive the claimed assets");

        // Verify the request is deleted after claiming
        vm.expectRevert(abi.encodeWithSelector(IWithdrawalQueue.WithdrawalQueue__InvalidRequest.selector, requestId));
        withdrawalQueue.getRequest(requestId);
    }
}
