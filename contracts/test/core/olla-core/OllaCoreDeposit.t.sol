// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20Permit } from "@oz/token/ERC20/extensions/IERC20Permit.sol";
import { ERC20Permit } from "@oz/token/ERC20/extensions/ERC20Permit.sol";
import { ECDSA } from "@oz/utils/cryptography/ECDSA.sol";
import { Math } from "@oz/utils/math/Math.sol";

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";
import { MockOllaGovernance } from "test/mocks/MockOllaGovernance.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

contract OllaCoreDepositTest is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed caller, address indexed recipient, uint256 assets, uint256 shares);

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
    OllaCoreHarness internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    address internal governance;
    address internal alice;
    address internal bob;
    address internal permitOwner;
    uint256 internal permitOwnerKey;
    uint256 internal permitAttackerKey;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        // Deploy Core
        OllaCoreHarness coreImplementation = new OllaCoreHarness();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCoreHarness(address(coreProxy));

        // Deploy Vault
        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        stakingManager = new MockAccountingStakingManager();
        governance = address(new MockOllaGovernance());
        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));

        stakingManager.setProviderRewardsRecipient(makeAddr("providerRewardsRecipient"));
        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));

        core.initialize(
            asset, stAztec, stakingManager, 500, 5_000, governance, rewardsAccumulator, address(safetyModule)
        );

        vault.initialize(asset, stAztec, address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));

        vm.prank(governance);
        core.unpause();

        vm.prank(governance);
        vault.unpause();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        permitOwnerKey = 0xA11CE;
        permitOwner = vm.addr(permitOwnerKey);
        permitAttackerKey = 0xB0B;
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
                                DEPOSITS
    //////////////////////////////////////////////////////////////*/

    function test_DepositMintsAtExchangeRate() external {
        uint256 depositAssetAmountAlice = 100 * DECIMALS;
        uint256 firstShares = _performDeposit(alice, depositAssetAmountAlice);
        assertEq(firstShares, depositAssetAmountAlice, "first deposit: 1:1 shares at zero supply");

        // `totalAssets()` reads the accumulator balance live from `rewardsAccumulator.balance()`,
        // so funding the accumulator directly with `deal` is the way to prime a non-zero
        // exchange rate for the next depositor.
        deal(address(asset), address(rewardsAccumulator), 50 * DECIMALS);

        uint256 totalAssetsBeforeSecondDeposit = core.totalAssets();
        uint256 totalSharesBeforeSecondDeposit = stAztec.totalSupply();

        uint256 depositAssetAmountBob = 50 * DECIMALS;
        uint256 expectedShares = (depositAssetAmountBob)
        .mulDiv(totalSharesBeforeSecondDeposit + 1e3, totalAssetsBeforeSecondDeposit + 1e3, Math.Rounding.Floor);
        uint256 secondShares = _performDeposit(bob, depositAssetAmountBob);

        assertEq(secondShares, expectedShares, "second deposit: shares follow exchange rate");
    }

    function test_DepositsAreInstant() external {
        uint256 shares = _performDeposit(alice, 10 * DECIMALS);

        assertEq(stAztec.balanceOf(alice), shares, "shares minted");
        assertEq(core.totalAssets(), 10 * DECIMALS, "assets buffered");
        IOllaCore.FlowCounters memory flows = core.flowCounters();
        assertEq(flows.cumulativeDeposits, 10 * DECIMALS, "cumulative deposits updated");
    }

    function test_Deposit3Arg_WithZeroMinShares() external {
        uint256 assets = 9 * DECIMALS;
        asset.mint(alice, assets);
        vm.prank(alice);
        asset.approve(address(vault), assets);

        vm.prank(alice);
        uint256 shares = vault.deposit(assets, alice, 0);

        assertEq(shares, assets, "deposit shares");
        assertEq(stAztec.balanceOf(alice), assets, "shares minted");
    }

    /*//////////////////////////////////////////////////////////////
                        ERC-4626 2-ARG DEPOSIT
    //////////////////////////////////////////////////////////////*/

    /// @notice The standard ERC-4626 deposit(assets, receiver) works.
    function test_Deposit2Arg_ERC4626() external {
        uint256 assets = 10 * DECIMALS;
        asset.mint(alice, assets);
        vm.prank(alice);
        asset.approve(address(vault), assets);

        vm.prank(alice);
        uint256 shares = vault.deposit(assets, alice);

        assertEq(shares, assets, "shares minted at 1:1");
        assertEq(stAztec.balanceOf(alice), assets, "shares balance");
        assertEq(core.totalAssets(), assets, "assets buffered");
    }

    /// @notice 2-arg and 3-arg deposit produce identical results.
    function testFuzz_Deposit2Arg_Matches3Arg(uint96 assetsSeed) external {
        uint256 assets = bound(uint256(assetsSeed), 1, type(uint96).max);

        // 2-arg deposit for alice
        asset.mint(alice, assets);
        vm.prank(alice);
        asset.approve(address(vault), assets);
        vm.prank(alice);
        uint256 shares2Arg = vault.deposit(assets, alice);

        // 3-arg deposit for bob (same amount, minSharesOut = 0)
        asset.mint(bob, assets);
        vm.prank(bob);
        asset.approve(address(vault), assets);
        vm.prank(bob);
        uint256 shares3Arg = vault.deposit(assets, bob, 0);

        assertEq(shares2Arg, shares3Arg, "2-arg and 3-arg deposit produce same shares");
    }

    /// @notice 2-arg deposit works at a non-trivial exchange rate.
    function test_Deposit2Arg_AtNonTrivialRate() external {
        // Seed initial deposit + rewards to move rate off 1:1
        _performDeposit(alice, 100 * DECIMALS);
        stakingManager.setClaimableRewards(50 * DECIMALS);
        core.updateAccounting();

        uint256 expectedShares = core.convertToShares(25 * DECIMALS);

        asset.mint(bob, 25 * DECIMALS);
        vm.prank(bob);
        asset.approve(address(vault), 25 * DECIMALS);
        vm.prank(bob);
        uint256 shares = vault.deposit(25 * DECIMALS, bob);

        assertEq(shares, expectedShares, "2-arg deposit follows exchange rate");
    }

    /// @notice 2-arg deposit emits the correct ERC-4626 Deposit event.
    function test_Deposit2Arg_EmitsEvent() external {
        uint256 assets = 5 * DECIMALS;
        asset.mint(alice, assets);
        vm.prank(alice);
        asset.approve(address(vault), assets);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Deposit(alice, alice, assets, assets);

        vm.prank(alice);
        vault.deposit(assets, alice);
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
        uint256 shares = vault.depositWithPermit(assets, permitOwner, 0, deadline, v, r, s);

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
        uint256 shares = vault.depositWithPermit(assets, permitOwner, 0, deadline, v, r, s);

        assertEq(shares, assets, "shares minted");
        assertEq(asset.allowance(permitOwner, address(vault)), type(uint256).max, "allowance remains max");
    }

    function test_RevertWhen_DepositWithPermit_ExpiredSignature() external {
        uint256 assets = 5 * DECIMALS;
        asset.mint(permitOwner, assets);

        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(IERC20Permit(address(asset)), permitOwner, permitOwnerKey, address(vault), assets, deadline);

        vm.expectRevert(
            abi.encodeWithSelector(
                IOllaVault.OllaVault__PermitFailed.selector,
                abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline)
            )
        );
        vm.prank(permitOwner);
        vault.depositWithPermit(assets, permitOwner, 0, deadline, v, r, s);
    }

    function test_RevertWhen_DepositWithPermit_InvalidSignature() external {
        uint256 assets = 5 * DECIMALS;
        asset.mint(permitOwner, assets);

        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(IERC20Permit(address(asset)), permitOwner, permitAttackerKey, address(vault), assets, deadline);

        vm.expectRevert(
            abi.encodeWithSelector(
                IOllaVault.OllaVault__PermitFailed.selector,
                abi.encodeWithSelector(
                    ERC20Permit.ERC2612InvalidSigner.selector, vm.addr(permitAttackerKey), permitOwner
                )
            )
        );
        vm.prank(permitOwner);
        vault.depositWithPermit(assets, permitOwner, 0, deadline, v, r, s);
    }

    function test_RevertWhen_DepositWithPermit_ReplayedNonce() external {
        uint256 assets = 6 * DECIMALS;
        asset.mint(permitOwner, assets * 2);

        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(IERC20Permit(address(asset)), permitOwner, permitOwnerKey, address(vault), assets, deadline);

        vm.prank(permitOwner);
        vault.depositWithPermit(assets, permitOwner, 0, deadline, v, r, s);

        uint256 nonce = IERC20Permit(address(asset)).nonces(permitOwner);
        bytes32 digest =
            _buildPermitDigest(IERC20Permit(address(asset)), permitOwner, address(vault), assets, nonce, deadline);
        address signer = ECDSA.recover(digest, v, r, s);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOllaVault.OllaVault__PermitFailed.selector,
                abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, signer, permitOwner)
            )
        );
        vm.prank(permitOwner);
        vault.depositWithPermit(assets, permitOwner, 0, deadline, v, r, s);
    }

    /*//////////////////////////////////////////////////////////////
                           FUZZED DEPOSITS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_DepositMintsShares(uint96 assets) external {
        assets = uint96(bound(assets, 1, type(uint96).max));

        uint256 shares = _performDeposit(alice, assets);

        assertEq(shares, assets, "shares minted at 1:1");
        assertEq(stAztec.balanceOf(alice), shares, "shares balance");
        assertEq(core.totalAssets(), assets, "assets buffered");
    }

    function testFuzz_MultiDepositorAtDifferentRates(uint96 deposit1, uint96 deposit2, uint96 rewards) external {
        deposit1 = uint96(bound(deposit1, 1e18, type(uint96).max / 2));
        deposit2 = uint96(bound(deposit2, 1e18, type(uint96).max / 2));
        rewards = uint96(bound(rewards, 1, type(uint96).max / 2));

        // Alice deposits at 1:1 rate
        _performDeposit(alice, deposit1);

        // Simulate rewards to change the exchange rate
        stakingManager.setClaimableRewards(rewards);
        core.updateAccounting();

        // Snapshot state before Bob's deposit
        uint256 supplyBeforeBob = stAztec.totalSupply();
        uint256 totalAssetsBeforeBob = core.totalAssets();

        // Bob deposits at new rate
        uint256 bobShares = _performDeposit(bob, deposit2);

        // Assert: Bob's shares follow the ERC4626 formula with virtual offset
        uint256 expectedBobShares =
            uint256(deposit2).mulDiv(supplyBeforeBob + 1e3, totalAssetsBeforeBob + 1e3, Math.Rounding.Floor);
        assertEq(bobShares, expectedBobShares, "Bob shares match ERC4626 formula");
    }
}
