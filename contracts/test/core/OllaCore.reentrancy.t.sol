// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";
import { MaliciousAztec } from "src/staking/mocks/MaliciousAztec.sol";
import { MaliciousWithdrawalQueue } from "src/core/mocks/MaliciousWithdrawalQueue.sol";

contract OllaCoreReentrancyTest is Test {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MaliciousAztec internal asset;
    OllaCore internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    MaliciousWithdrawalQueue internal withdrawalQueue;
    MockSafetyModule internal safetyModule;
    address internal governance;
    address internal rewardsVault;
    address internal alice;
    address internal bob;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MaliciousAztec();

        OllaCore implementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        vault = OllaCore(address(proxy));

        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        governance = makeAddr("governance");
        rewardsVault = makeAddr("rewardsVault");
        safetyModule = new MockSafetyModule();
        withdrawalQueue = new MaliciousWithdrawalQueue();

        vault.initialize(
            asset, stAztec, stakingManager, governance, address(withdrawalQueue), rewardsVault, address(safetyModule)
        );
        withdrawalQueue.initialize(address(vault), governance);

        vm.startPrank(governance);
        vault.grantRole(vault.OPERATOR_ROLE(), address(withdrawalQueue));
        vm.stopPrank();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _deposit(address owner, uint256 assets) internal {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        vault.deposit(assets, owner);
    }

    /*//////////////////////////////////////////////////////////////
                               DEPOSITS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_Deposit_ReenteredFromTransferFrom() external {
        uint256 assets = 5 * DECIMALS;

        asset.mint(alice, assets);
        vm.prank(alice);
        asset.approve(address(vault), assets);

        asset.mint(address(asset), assets);
        asset.setSelfAllowance(assets);
        asset.configureReentry(address(vault), abi.encodeCall(vault.deposit, (assets, alice)), true);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        vault.deposit(assets, alice);
    }

    /*//////////////////////////////////////////////////////////////
                            REQUEST REDEEM
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_RequestRedeem_ReenteredFromQueue() external {
        _deposit(alice, 10 * DECIMALS);

        uint256 shares = 2 * DECIMALS;
        withdrawalQueue.setReentry(address(vault), abi.encodeCall(vault.requestRedeem, (shares, bob)));
        withdrawalQueue.setReenterOnRequest(true);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        vault.requestRedeem(shares, bob);
    }

    /*//////////////////////////////////////////////////////////////
                             CLAIM REQUEST
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_ClaimActiveRequest_ReenteredFromQueue() external {
        _deposit(alice, 10 * DECIMALS);

        uint256 shares = 2 * DECIMALS;
        vm.prank(alice);
        vault.requestRedeem(shares, bob);

        withdrawalQueue.setReentry(address(vault), abi.encodeCall(vault.claimActiveRequest, (alice)));
        withdrawalQueue.setReenterOnClaim(true);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vault.claimActiveRequest(alice);
    }

    function test_RevertWhen_ClaimRequestById_ReenteredFromQueue() external {
        _deposit(alice, 10 * DECIMALS);

        uint256 shares = 2 * DECIMALS;
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, bob);

        withdrawalQueue.setReentry(address(vault), abi.encodeCall(vault.claimRequestById, (requestId)));
        withdrawalQueue.setReenterOnClaim(true);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vault.claimRequestById(requestId);
    }

    /*//////////////////////////////////////////////////////////////
                          FINALIZE WITHDRAWALS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_FinalizeWithdrawals_ReenteredFromQueue() external {
        _deposit(alice, 10 * DECIMALS);

        uint256 available = 1 * DECIMALS;
        withdrawalQueue.setReentry(address(vault), abi.encodeCall(vault.finalizeWithdrawals, (available)));
        withdrawalQueue.setReenterOnFinalize(true);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(governance);
        vault.finalizeWithdrawals(available);
    }
}
