// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

/// @title OllaCore ReentrancyGuard Proxy Compatibility Tests
/// @notice Verifies transient reentrancy protection works correctly behind the protocol proxies.

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { ReentrancyGuardTransient } from "@oz/utils/ReentrancyGuardTransient.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { IRewardsAccumulator } from "src/core/interfaces/IRewardsAccumulator.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockWithdrawalQueue } from "src/vault/mocks/MockWithdrawalQueue.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MaliciousAztec } from "src/staking/mocks/MaliciousAztec.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";

contract OllaCoreReentrancyGuardProxyTest is Test {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;

    /*//////////////////////////////////////////////////////////////
                            TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MaliciousAztec internal asset;
    OllaCore internal implementation;
    ERC1967Proxy internal coreProxy;
    OllaCore internal core;
    OllaVault internal vaultImplementation;
    OllaVault internal vault;
    ERC1967Proxy internal vaultProxy;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    MockWithdrawalQueue internal withdrawalQueue;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;
    address internal governance;
    address internal alice;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MaliciousAztec();

        implementation = new OllaCore();
        coreProxy = new ERC1967Proxy(address(implementation), "");
        core = OllaCore(address(coreProxy));

        vaultImplementation = new OllaVault();
        vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(implementation), address(vault));
        withdrawalQueue = new MockWithdrawalQueue();

        alice = makeAddr("alice");
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Initializes the vault proxy with standard test parameters.
    function _initializeVault() internal {
        core.initialize(
            asset,
            stAztec,
            stakingManager,
            500,
            5_000,
            governance,
            IRewardsAccumulator(address(rewardsAccumulator)),
            address(safetyModule)
        );
        vault.initialize(asset, stAztec, address(withdrawalQueue), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();

        withdrawalQueue.initialize(address(vault), governance, 180_000);
    }

    /*//////////////////////////////////////////////////////////////
              FIRST NONREENTRANT CALL SUCCEEDS ON PROXY
    //////////////////////////////////////////////////////////////*/

    /// @notice The first protected call on the proxy must succeed without any
    ///         constructor or initializer priming.
    function test_Deposit_FirstNonReentrantCallSucceeds() external {
        _initializeVault();

        uint256 amount = 10 * DECIMALS;
        asset.mint(alice, amount);
        vm.prank(alice);
        asset.approve(address(vault), amount);

        // First nonReentrant call -- must not revert
        vm.prank(alice);
        uint256 shares = vault.deposit(amount, alice, 0);

        assertGt(shares, 0, "shares should be > 0");
        assertEq(stAztec.balanceOf(alice), shares, "alice should hold minted shares");
    }

    /*//////////////////////////////////////////////////////////////
              REENTRANCY BLOCKED ON PROXY
    //////////////////////////////////////////////////////////////*/

    /// @notice A reentrant call to `deposit` via a malicious `transferFrom`
    ///         hook must be blocked by the guard, even on the proxy.
    function test_RevertWhen_Deposit_ReenteredOnProxy() external {
        _initializeVault();

        uint256 amount = 5 * DECIMALS;

        // Give alice tokens and approval for the outer deposit
        asset.mint(alice, amount);
        vm.prank(alice);
        asset.approve(address(vault), amount);

        // Fund the MaliciousAztec contract itself so it can perform the reentrant
        // deposit (transferFrom hook calls deposit before completing)
        asset.mint(address(asset), amount);
        asset.setSelfAllowance(amount);
        asset.configureReentry(
            address(vault),
            abi.encodeWithSelector(bytes4(keccak256("deposit(uint256,address,uint256)")), amount, alice, 0),
            true
        );

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        vault.deposit(amount, alice, 0);
    }

    /*//////////////////////////////////////////////////////////////
                  MULTIPLE CALLS REMAIN USABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Transient guard state clears at the end of the call, so later
    ///         protected calls on the proxy still succeed.
    function test_Deposit_MultipleSequentialCallsSucceed() external {
        _initializeVault();

        // First deposit
        uint256 amount = 1 * DECIMALS;
        asset.mint(alice, amount);
        vm.prank(alice);
        asset.approve(address(vault), amount);
        vm.prank(alice);
        vault.deposit(amount, alice, 0);

        // Second deposit also succeeds
        asset.mint(alice, amount);
        vm.prank(alice);
        asset.approve(address(vault), amount);
        vm.prank(alice);
        uint256 shares = vault.deposit(amount, alice, 0);
        assertGt(shares, 0, "second deposit should succeed");
    }
}
