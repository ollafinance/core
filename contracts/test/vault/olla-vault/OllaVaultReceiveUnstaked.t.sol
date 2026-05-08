// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockStakingManager } from "src/staking/mocks/MockStakingManager.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";

contract OllaVaultReceiveUnstakedTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event UnstakedAssetsReceived(uint256 amount);

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
    MockStakingManager internal stakingManager;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;
    address internal governance;

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule));
        vault.initialize(asset, stAztec, address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();
    }

    /*//////////////////////////////////////////////////////////////
                      receiveUnstaked -- HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    /// @notice receiveUnstaked succeeds when tokens are transferred before the call.
    function test_ReceiveUnstaked_WithMatchingTransfer() external {
        uint256 amount = 10 * DECIMALS;

        // Transfer tokens to the vault first, then notify.
        asset.mint(address(core), amount);
        vm.startPrank(address(core));
        asset.transfer(address(vault), amount);

        vm.expectEmit(true, true, true, true, address(vault));
        emit UnstakedAssetsReceived(amount);

        vault.receiveUnstaked(amount);
        vm.stopPrank();

        assertEq(vault.bufferedAssets(), amount, "buffered assets updated");
    }

    /// @notice receiveUnstaked succeeds when the vault holds more tokens than required (e.g. donation).
    function test_ReceiveUnstaked_WithExcessBalance() external {
        uint256 amount = 5 * DECIMALS;
        uint256 bonus = 2 * DECIMALS;

        // Vault receives amount + bonus, but receiveUnstaked is only called for amount.
        asset.mint(address(vault), amount + bonus);

        vm.prank(address(core));
        vault.receiveUnstaked(amount);

        assertEq(vault.bufferedAssets(), amount, "buffered only tracks notified amount");
    }

    /*//////////////////////////////////////////////////////////////
              receiveUnstaked -- BALANCE MISMATCH REVERT
    //////////////////////////////////////////////////////////////*/

    /// @notice receiveUnstaked reverts when called without transferring tokens.
    function test_RevertWhen_ReceiveUnstaked_WithoutTransfer() external {
        uint256 amount = 10 * DECIMALS;

        vm.prank(address(core));
        vm.expectRevert(abi.encodeWithSelector(IOllaVault.OllaVault__BufferedBalanceMismatch.selector, amount, 0));
        vault.receiveUnstaked(amount);
    }

    /// @notice receiveUnstaked reverts when fewer tokens were transferred than claimed.
    function test_RevertWhen_ReceiveUnstaked_WithPartialTransfer() external {
        uint256 claimed = 10 * DECIMALS;
        uint256 actual = 7 * DECIMALS;

        asset.mint(address(vault), actual);

        vm.prank(address(core));
        vm.expectRevert(abi.encodeWithSelector(IOllaVault.OllaVault__BufferedBalanceMismatch.selector, claimed, actual));
        vault.receiveUnstaked(claimed);
    }

    /// @notice Cumulative mismatch: first call succeeds, second reverts when balance is short.
    function test_RevertWhen_ReceiveUnstaked_CumulativeMismatch() external {
        uint256 first = 5 * DECIMALS;
        uint256 second = 5 * DECIMALS;

        // Only transfer enough for the first call.
        asset.mint(address(vault), first);

        vm.startPrank(address(core));
        vault.receiveUnstaked(first);

        // Second call without additional transfer.
        vm.expectRevert(
            abi.encodeWithSelector(IOllaVault.OllaVault__BufferedBalanceMismatch.selector, first + second, first)
        );
        vault.receiveUnstaked(second);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    receiveUnstaked -- ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice Only CORE_ROLE can call receiveUnstaked.
    function test_RevertWhen_ReceiveUnstaked_CalledByNonCore() external {
        address alice = makeAddr("alice");
        asset.mint(address(vault), 1 * DECIMALS);

        vm.prank(alice);
        vm.expectRevert();
        vault.receiveUnstaked(1 * DECIMALS);
    }

    /*//////////////////////////////////////////////////////////////
                      receiveUnstaked -- FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz: receiveUnstaked always succeeds when balance covers the amount.
    function testFuzz_ReceiveUnstaked_SucceedsWithSufficientBalance(uint256 amount, uint256 extra) external {
        amount = bound(amount, 1, 1_000_000 * DECIMALS);
        extra = bound(extra, 0, 1_000_000 * DECIMALS);

        asset.mint(address(vault), amount + extra);

        vm.prank(address(core));
        vault.receiveUnstaked(amount);

        assertEq(vault.bufferedAssets(), amount, "buffered tracks notified amount");
    }

    /// @notice Fuzz: receiveUnstaked always reverts when balance is short.
    function testFuzz_ReceiveUnstaked_RevertsWithInsufficientBalance(uint256 amount, uint256 deficit) external {
        amount = bound(amount, 2, 1_000_000 * DECIMALS);
        deficit = bound(deficit, 1, amount - 1);

        uint256 transferred = amount - deficit;
        asset.mint(address(vault), transferred);

        vm.prank(address(core));
        vm.expectRevert(
            abi.encodeWithSelector(IOllaVault.OllaVault__BufferedBalanceMismatch.selector, amount, transferred)
        );
        vault.receiveUnstaked(amount);
    }
}
