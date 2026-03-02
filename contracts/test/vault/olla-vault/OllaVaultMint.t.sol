// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "@oz/utils/math/Math.sol";

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/vault/mocks/MockWithdrawalQueue.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

contract OllaVaultMintTest is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed caller, address indexed recipient, uint256 assets, uint256 shares);

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCoreHarness internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    address internal governance;
    address internal alice;
    address internal bob;
    MockWithdrawalQueue internal withdrawalQueue;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreHarness coreImplementation = new OllaCoreHarness();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCoreHarness(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        stakingManager = new MockAccountingStakingManager();
        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));
        withdrawalQueue = new MockWithdrawalQueue();

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));

        core.initialize(asset, stAztec, stakingManager, 0, 5_000, governance, rewardsAccumulator, address(safetyModule));

        vault.initialize(asset, stAztec, address(withdrawalQueue), address(safetyModule), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));

        vm.prank(governance);
        core.unpause();

        vm.prank(governance);
        vault.unpause();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _performDeposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner, 0);
        return shares;
    }

    function _performMint(address owner, uint256 shares) internal returns (uint256 assets) {
        uint256 expectedAssets = core.convertToAssetsCeil(shares);
        asset.mint(owner, expectedAssets);
        vm.prank(owner);
        asset.approve(address(vault), expectedAssets);
        vm.prank(owner);
        assets = vault.mint(shares, owner);
        return assets;
    }

    /*//////////////////////////////////////////////////////////////
                          ERC-4626 MINT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice mint() at 1:1 rate mints exact shares.
    function test_Mint_AtOneToOneRate() external {
        uint256 shares = 10 * DECIMALS;
        uint256 assets = _performMint(alice, shares);

        assertEq(assets, shares, "assets should equal shares at 1:1");
        assertEq(stAztec.balanceOf(alice), shares, "exact shares minted");
    }

    /// @notice mint() at a non-trivial exchange rate mints exact shares.
    function test_Mint_AtNonTrivialRate() external {
        // Seed initial deposit + rewards to move rate off 1:1
        _performDeposit(alice, 100 * DECIMALS);
        stakingManager.setClaimableRewards(50 * DECIMALS);
        bytes32 operatorRole = core.OPERATOR_ROLE();
        vm.prank(governance);
        core.grantRole(operatorRole, address(this));
        core.updateAccounting();

        uint256 sharesToMint = 20 * DECIMALS;
        uint256 expectedAssets = core.convertToAssetsCeil(sharesToMint);

        uint256 balanceBefore = stAztec.balanceOf(bob);
        uint256 assets = _performMint(bob, sharesToMint);

        uint256 actualShares = stAztec.balanceOf(bob) - balanceBefore;
        assertEq(actualShares, sharesToMint, "exact shares minted at non-trivial rate");
        assertEq(assets, expectedAssets, "assets match previewMint");
    }

    /// @notice mint() returns the same value as previewMint().
    function test_Mint_MatchesPreviewMint() external {
        _performDeposit(alice, 100 * DECIMALS);
        stakingManager.setClaimableRewards(33 * DECIMALS);
        bytes32 operatorRole = core.OPERATOR_ROLE();
        vm.prank(governance);
        core.grantRole(operatorRole, address(this));
        core.updateAccounting();

        uint256 sharesToMint = 15 * DECIMALS;
        uint256 preview = vault.previewMint(sharesToMint);
        uint256 assets = _performMint(bob, sharesToMint);

        assertEq(assets, preview, "mint() returns same as previewMint()");
    }

    /// @notice mint() emits the correct Deposit event.
    function test_Mint_EmitsDepositEvent() external {
        uint256 shares = 5 * DECIMALS;
        uint256 expectedAssets = core.convertToAssetsCeil(shares);

        asset.mint(alice, expectedAssets);
        vm.prank(alice);
        asset.approve(address(vault), expectedAssets);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Deposit(alice, alice, expectedAssets, shares);

        vm.prank(alice);
        vault.mint(shares, alice);
    }

    /// @notice mint() reverts on zero shares.
    function test_RevertWhen_Mint_ZeroShares() external {
        vm.expectRevert(IOllaVault.OllaVault__InvalidAmount.selector);
        vm.prank(alice);
        vault.mint(0, alice);
    }

    /// @notice mint() reverts on zero receiver.
    function test_RevertWhen_Mint_ZeroReceiver() external {
        vm.expectRevert(abi.encodeWithSelector(IOllaVault.OllaVault__ZeroAddress.selector, "receiver"));
        vm.prank(alice);
        vault.mint(1, address(0));
    }

    /// @notice Fuzz: mint() always mints exactly the requested shares.
    function testFuzz_Mint_ExactShares(uint96 sharesSeed) external {
        uint256 shares = bound(uint256(sharesSeed), 1, type(uint96).max);

        uint256 balanceBefore = stAztec.balanceOf(alice);
        _performMint(alice, shares);
        uint256 actualShares = stAztec.balanceOf(alice) - balanceBefore;

        assertEq(actualShares, shares, "exact shares minted");
    }

    /// @notice Fuzz: mint() at various exchange rates always mints exact shares.
    function testFuzz_Mint_ExactSharesAtVariousRates(uint96 deposit, uint96 rewards, uint96 sharesSeed) external {
        deposit = uint96(bound(deposit, 1e18, type(uint96).max / 2));
        rewards = uint96(bound(rewards, 1, type(uint96).max / 2));
        uint256 shares = bound(uint256(sharesSeed), 1, type(uint96).max / 4);

        _performDeposit(alice, deposit);

        stakingManager.setClaimableRewards(rewards);
        bytes32 operatorRole = core.OPERATOR_ROLE();
        vm.prank(governance);
        core.grantRole(operatorRole, address(this));
        core.updateAccounting();

        uint256 balanceBefore = stAztec.balanceOf(bob);
        _performMint(bob, shares);
        uint256 actualShares = stAztec.balanceOf(bob) - balanceBefore;

        assertEq(actualShares, shares, "exact shares minted at non-trivial rate");
    }
}
