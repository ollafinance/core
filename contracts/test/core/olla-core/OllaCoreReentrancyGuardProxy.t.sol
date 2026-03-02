// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.27 <0.9.0;

/// @title OllaCore ReentrancyGuard Proxy Compatibility Tests
/// @notice Verifies that OpenZeppelin 5.x's non-upgradeable `ReentrancyGuard` works correctly
///         behind UUPS proxies as used by the Olla protocol.
///
///         Background:
///         - OZ 5.x removed `ReentrancyGuardUpgradeable` and annotated `ReentrancyGuard` with
///           `@custom:stateless`, meaning it uses ERC-7201 namespaced storage and is safe for
///           both upgradeable and non-upgradeable contracts.
///         - The `ReentrancyGuard` constructor sets the namespaced slot to `NOT_ENTERED (1)`,
///           but this only executes on the **implementation** — not on the proxy.
///         - On a freshly deployed proxy the slot starts at `0` (uninitialized).
///         - The guard still works because `_reentrancyGuardEntered()` checks `value == ENTERED (2)`,
///           so `0` passes the check just as `1` does.
///         - After the first `nonReentrant` call completes, `_nonReentrantAfter()` writes `1`
///           (`NOT_ENTERED`) to the slot, normalizing it going forward.
///
///         These tests document and verify these assumptions end-to-end on an actual OllaCore proxy.

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { ReentrancyGuard } from "@oz/utils/ReentrancyGuard.sol";

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

    /// @dev ERC-7201 namespaced storage slot for ReentrancyGuard.
    /// keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReentrancyGuard")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant REENTRANCY_GUARD_SLOT =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

    /// @dev The value OZ ReentrancyGuard writes when a nonReentrant call completes.
    uint256 internal constant NOT_ENTERED = 1;

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
        vault.initialize(asset, stAztec, address(withdrawalQueue), address(safetyModule), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();

        withdrawalQueue.initialize(address(vault), governance, 180_000);
    }

    /*//////////////////////////////////////////////////////////////
                    SLOT VALUE BEFORE INITIALIZE
    //////////////////////////////////////////////////////////////*/

    /// @notice Documents that on a fresh proxy (before `initialize()`), the
    ///         ReentrancyGuard slot is `0`.  The guard is safe because
    ///         `_reentrancyGuardEntered()` checks `value == ENTERED (2)`, so
    ///         `0` passes just like `1`.
    function test_ReentrancyGuardSlot_IsZeroBeforeInitialize() external view {
        bytes32 slotValue = vm.load(address(vaultProxy), REENTRANCY_GUARD_SLOT);
        assertEq(uint256(slotValue), 0, "slot should be 0 (uninitialized) on fresh proxy");
    }

    /*//////////////////////////////////////////////////////////////
                    SLOT VALUE AFTER INITIALIZE
    //////////////////////////////////////////////////////////////*/

    /// @notice Proves that `initialize()` does NOT touch the ReentrancyGuard
    ///         slot — it remains `0`.  This confirms the guard does not rely
    ///         on an `__ReentrancyGuard_init()` call.
    function test_ReentrancyGuardSlot_RemainsZeroAfterInitialize() external {
        _initializeVault();

        bytes32 slotValue = vm.load(address(vaultProxy), REENTRANCY_GUARD_SLOT);
        assertEq(uint256(slotValue), 0, "slot should still be 0 after initialize()");
    }

    /*//////////////////////////////////////////////////////////////
              FIRST NONREENTRANT CALL SUCCEEDS ON PROXY
    //////////////////////////////////////////////////////////////*/

    /// @notice The first `nonReentrant` call on the proxy must succeed even
    ///         though the slot starts at `0` instead of `NOT_ENTERED (1)`.
    ///         After the call the slot is set to `NOT_ENTERED (1)`.
    function test_Deposit_FirstNonReentrantCallSucceeds() external {
        _initializeVault();

        uint256 amount = 10 * DECIMALS;
        asset.mint(alice, amount);
        vm.prank(alice);
        asset.approve(address(vault), amount);

        // First nonReentrant call — must not revert
        vm.prank(alice);
        uint256 shares = vault.deposit(amount, alice, 0);

        assertGt(shares, 0, "shares should be > 0");
        assertEq(stAztec.balanceOf(alice), shares, "alice should hold minted shares");

        // After the call, the slot must be normalised to NOT_ENTERED (1)
        bytes32 slotValue = vm.load(address(vaultProxy), REENTRANCY_GUARD_SLOT);
        assertEq(uint256(slotValue), NOT_ENTERED, "slot should be NOT_ENTERED (1) after first call");
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

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        vault.deposit(amount, alice, 0);
    }

    /*//////////////////////////////////////////////////////////////
          IMPLEMENTATION SLOT VS PROXY SLOT
    //////////////////////////////////////////////////////////////*/

    /// @notice Confirms the implementation's constructor sets its own slot to
    ///         `NOT_ENTERED (1)`, while the proxy's slot remains `0`.
    ///         This highlights the decoupling between implementation and proxy
    ///         storage, which the ERC-7201 + stateless pattern handles safely.
    function test_ReentrancyGuardSlot_ImplementationVsProxy() external view {
        // Implementation slot — set to 1 by the constructor
        bytes32 implSlot = vm.load(address(vaultImplementation), REENTRANCY_GUARD_SLOT);
        assertEq(uint256(implSlot), NOT_ENTERED, "implementation slot should be NOT_ENTERED (1)");

        // Proxy slot — uninitialised, defaults to 0
        bytes32 proxySlot = vm.load(address(vaultProxy), REENTRANCY_GUARD_SLOT);
        assertEq(uint256(proxySlot), 0, "proxy slot should be 0 (uninitialized)");
    }

    /*//////////////////////////////////////////////////////////////
          SLOT NORMALIZED AFTER FIRST CALL
    //////////////////////////////////////////////////////////////*/

    /// @notice After the very first `nonReentrant` call on the proxy, the slot
    ///         transitions from `0` → `2` (ENTERED) → `1` (NOT_ENTERED).
    ///         Subsequent calls therefore start from `1`, identical to a
    ///         non-proxy deployment.
    function test_ReentrancyGuardSlot_NormalizedAfterFirstDeposit() external {
        _initializeVault();

        // Before any call: slot is 0
        assertEq(uint256(vm.load(address(vaultProxy), REENTRANCY_GUARD_SLOT)), 0, "pre-call: slot should be 0");

        // First deposit
        uint256 amount = 1 * DECIMALS;
        asset.mint(alice, amount);
        vm.prank(alice);
        asset.approve(address(vault), amount);
        vm.prank(alice);
        vault.deposit(amount, alice, 0);

        // After first call: slot is 1
        assertEq(
            uint256(vm.load(address(vaultProxy), REENTRANCY_GUARD_SLOT)),
            NOT_ENTERED,
            "post-first-call: slot should be NOT_ENTERED (1)"
        );

        // Second deposit also succeeds
        asset.mint(alice, amount);
        vm.prank(alice);
        asset.approve(address(vault), amount);
        vm.prank(alice);
        uint256 shares = vault.deposit(amount, alice, 0);
        assertGt(shares, 0, "second deposit should succeed");

        // Slot remains NOT_ENTERED after the second call
        assertEq(
            uint256(vm.load(address(vaultProxy), REENTRANCY_GUARD_SLOT)),
            NOT_ENTERED,
            "post-second-call: slot should still be NOT_ENTERED (1)"
        );
    }
}
