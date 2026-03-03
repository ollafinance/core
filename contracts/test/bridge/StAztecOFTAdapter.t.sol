// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

// LayerZero test helpers
import { TestHelperOz5 } from "@lz-test/contracts/TestHelperOz5.sol";

// LayerZero OFT imports
import { IOFT, SendParam, OFTReceipt } from "@lz-oft/contracts/interfaces/IOFT.sol";
import { MessagingFee, MessagingReceipt } from "@lz-oft/contracts/OFTCore.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

// Project imports
import { StAztec } from "src/vault/StAztec.sol";
import { StAztecOFTAdapter } from "src/bridge/StAztecOFTAdapter.sol";
import { OFTMock } from "@lz-oft/test/mocks/OFTMock.sol";

/// @title StAztecOFTAdapterTest
/// @notice Foundry tests for the StAztecOFTAdapter (lock/unlock on home chain).
/// @dev Uses LayerZero's TestHelperOz5 to simulate a two-chain environment with
///      UltraLightNode message verification. An OFTMock stands in as the
///      destination-chain OFT counterpart.
contract StAztecOFTAdapterTest is TestHelperOz5 {
    using OptionsBuilder for bytes;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint32 private constant HOME_EID = 1;
    uint32 private constant DEST_EID = 2;
    uint256 private constant INITIAL_BALANCE = 100 ether;

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    /// @dev Mock OllaCore address (authorized to mint stAztec).
    address private mockOllaCore;

    /// @dev StAztec token on the home chain.
    StAztec private stAztec;

    /// @dev OFTAdapter on the home chain (locks/unlocks stAztec).
    StAztecOFTAdapter private adapter;

    /// @dev Mock OFT on the destination chain (stands in for the real bridged token).
    OFTMock private oft;

    /// @dev Test users.
    address private userA;
    address private userB;
    address private owner;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual override {
        userA = makeAddr("userA");
        userB = makeAddr("userB");
        owner = makeAddr("owner");
        mockOllaCore = makeAddr("mockOllaCore");

        vm.deal(userA, 1000 ether);
        vm.deal(userB, 1000 ether);

        super.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        // Deploy stAztec with mockOllaCore as the authorized minter.
        stAztec = new StAztec(mockOllaCore);

        // Deploy StAztecOFTAdapter on the home chain.
        // Use address(this) as delegate so wireOApps() can call setPeer.
        adapter = StAztecOFTAdapter(
            _deployOApp(
                type(StAztecOFTAdapter).creationCode,
                abi.encode(address(stAztec), address(endpoints[HOME_EID]), address(this))
            )
        );

        // Deploy OFTMock on the destination chain.
        // Use address(this) as delegate so wireOApps() can call setPeer.
        oft = OFTMock(
            _deployOApp(
                type(OFTMock).creationCode,
                abi.encode("stAztec", "stAZTEC", address(endpoints[DEST_EID]), address(this))
            )
        );

        // Wire the OApps (set peers on both sides).
        address[] memory oapps = new address[](2);
        oapps[0] = address(adapter);
        oapps[1] = address(oft);
        this.wireOApps(oapps);

        // Mint stAztec to userA via mockOllaCore.
        vm.prank(mockOllaCore);
        stAztec.mint(userA, INITIAL_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                             HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Builds default options with 200k gas for lzReceive.
    function _defaultOptions() internal pure returns (bytes memory) {
        return OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
    }

    /// @dev Builds a SendParam for bridging `amount` from home → destination.
    function _sendParamHomeToDestination(address to, uint256 amount) internal pure returns (SendParam memory) {
        return SendParam({
            dstEid: DEST_EID,
            to: addressToBytes32(to),
            amountLD: amount,
            minAmountLD: amount,
            extraOptions: _defaultOptions(),
            composeMsg: "",
            oftCmd: ""
        });
    }

    /// @dev Builds a SendParam for bridging `amount` from destination → home.
    function _sendParamDestinationToHome(address to, uint256 amount) internal pure returns (SendParam memory) {
        return SendParam({
            dstEid: HOME_EID,
            to: addressToBytes32(to),
            amountLD: amount,
            minAmountLD: amount,
            extraOptions: _defaultOptions(),
            composeMsg: "",
            oftCmd: ""
        });
    }

    /*//////////////////////////////////////////////////////////////
                      TEST: CONSTRUCTOR / SETUP
    //////////////////////////////////////////////////////////////*/

    function test_constructor_adapter() public view {
        assertEq(adapter.token(), address(stAztec), "adapter.token should be stAztec");
        assertEq(adapter.owner(), address(this), "adapter owner should be test contract (delegate)");
        assertTrue(adapter.approvalRequired(), "adapter requires token approval");
    }

    function test_initial_balances() public view {
        assertEq(stAztec.balanceOf(userA), INITIAL_BALANCE);
        assertEq(oft.balanceOf(userB), 0);
    }

    /*//////////////////////////////////////////////////////////////
                  TEST: BRIDGE HOME → DESTINATION
    //////////////////////////////////////////////////////////////*/

    function test_bridge_home_to_destination() public {
        uint256 tokensToSend = 1 ether;
        SendParam memory sendParam = _sendParamHomeToDestination(userB, tokensToSend);
        MessagingFee memory fee = adapter.quoteSend(sendParam, false);

        // Approve the adapter to lock stAztec.
        vm.prank(userA);
        stAztec.approve(address(adapter), tokensToSend);

        // Send from home chain.
        vm.prank(userA);
        adapter.send{ value: fee.nativeFee }(sendParam, fee, payable(userA));

        // Verify tokens locked in adapter.
        assertEq(stAztec.balanceOf(userA), INITIAL_BALANCE - tokensToSend);
        assertEq(stAztec.balanceOf(address(adapter)), tokensToSend);

        // Deliver the LayerZero message to destination.
        verifyPackets(DEST_EID, addressToBytes32(address(oft)));

        // Verify tokens minted on destination.
        assertEq(oft.balanceOf(userB), tokensToSend);
    }

    /*//////////////////////////////////////////////////////////////
                  TEST: BRIDGE DESTINATION → HOME
    //////////////////////////////////////////////////////////////*/

    function test_bridge_destination_to_home() public {
        // First, bridge tokens to destination so userB has a balance.
        uint256 tokensToSend = 1 ether;
        _bridgeToDestination(userA, userB, tokensToSend);

        // Now bridge back from destination to home.
        SendParam memory sendParam = _sendParamDestinationToHome(userA, tokensToSend);
        MessagingFee memory fee = oft.quoteSend(sendParam, false);

        vm.prank(userB);
        oft.send{ value: fee.nativeFee }(sendParam, fee, payable(userB));

        // Verify tokens burned on destination.
        assertEq(oft.balanceOf(userB), 0);

        // Deliver message back to home chain.
        verifyPackets(HOME_EID, addressToBytes32(address(adapter)));

        // Verify tokens unlocked on home chain.
        assertEq(stAztec.balanceOf(userA), INITIAL_BALANCE);
        assertEq(stAztec.balanceOf(address(adapter)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                     TEST: ROUND TRIP
    //////////////////////////////////////////////////////////////*/

    function test_round_trip() public {
        uint256 tokensToSend = 10 ether;

        // Bridge home → destination.
        _bridgeToDestination(userA, userB, tokensToSend);
        assertEq(stAztec.balanceOf(userA), INITIAL_BALANCE - tokensToSend);
        assertEq(oft.balanceOf(userB), tokensToSend);

        // Bridge destination → home.
        _bridgeToHome(userB, userA, tokensToSend);
        assertEq(stAztec.balanceOf(userA), INITIAL_BALANCE);
        assertEq(oft.balanceOf(userB), 0);
        assertEq(stAztec.balanceOf(address(adapter)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                       TEST: QUOTE FEES
    //////////////////////////////////////////////////////////////*/

    function test_quoteSend() public view {
        uint256 tokensToSend = 1 ether;
        SendParam memory sendParam = _sendParamHomeToDestination(userB, tokensToSend);

        MessagingFee memory fee = adapter.quoteSend(sendParam, false);
        assertGt(fee.nativeFee, 0, "native fee should be > 0");
    }

    /*//////////////////////////////////////////////////////////////
                      TEST: ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_setPeer_onlyOwner() public {
        bytes32 fakePeer = bytes32(uint256(1));

        // Non-owner cannot set peer.
        vm.prank(userA);
        vm.expectRevert();
        adapter.setPeer(999, fakePeer);

        // Owner (address(this)) can set peer.
        adapter.setPeer(999, fakePeer);
    }

    /*//////////////////////////////////////////////////////////////
                       TEST: EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_send_zero_amount_no_state_change() public {
        SendParam memory sendParam = _sendParamHomeToDestination(userB, 0);
        MessagingFee memory fee = adapter.quoteSend(sendParam, false);

        vm.prank(userA);
        stAztec.approve(address(adapter), 0);

        // LZ allows zero-amount sends (no-op transfer). Verify no balances change.
        vm.prank(userA);
        adapter.send{ value: fee.nativeFee }(sendParam, fee, payable(userA));

        assertEq(stAztec.balanceOf(userA), INITIAL_BALANCE);
        assertEq(stAztec.balanceOf(address(adapter)), 0);
    }

    function test_revert_insufficient_balance() public {
        uint256 tooMuch = INITIAL_BALANCE + 1;

        // quoteSend reverts with SlippageExceeded because minAmountLD > available
        // supply after OFT shared-decimals rounding. We verify the send path
        // also reverts (use a fee estimate from a valid amount instead).
        SendParam memory validParam = _sendParamHomeToDestination(userB, INITIAL_BALANCE);
        MessagingFee memory fee = adapter.quoteSend(validParam, false);

        SendParam memory sendParam = _sendParamHomeToDestination(userB, tooMuch);

        vm.prank(userA);
        stAztec.approve(address(adapter), tooMuch);

        vm.prank(userA);
        vm.expectRevert();
        adapter.send{ value: fee.nativeFee }(sendParam, fee, payable(userA));
    }

    function test_revert_no_approval() public {
        uint256 tokensToSend = 1 ether;
        SendParam memory sendParam = _sendParamHomeToDestination(userB, tokensToSend);
        MessagingFee memory fee = adapter.quoteSend(sendParam, false);

        // Don't approve — should revert.
        vm.prank(userA);
        vm.expectRevert();
        adapter.send{ value: fee.nativeFee }(sendParam, fee, payable(userA));
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Bridges `amount` of stAztec from the home chain to destination.
    function _bridgeToDestination(address from, address to, uint256 amount) internal {
        SendParam memory sendParam = _sendParamHomeToDestination(to, amount);
        MessagingFee memory fee = adapter.quoteSend(sendParam, false);

        vm.prank(from);
        stAztec.approve(address(adapter), amount);

        vm.prank(from);
        adapter.send{ value: fee.nativeFee }(sendParam, fee, payable(from));

        verifyPackets(DEST_EID, addressToBytes32(address(oft)));
    }

    /// @dev Bridges `amount` of bridged stAztec back from destination to home.
    function _bridgeToHome(address from, address to, uint256 amount) internal {
        SendParam memory sendParam = _sendParamDestinationToHome(to, amount);
        MessagingFee memory fee = oft.quoteSend(sendParam, false);

        vm.prank(from);
        oft.send{ value: fee.nativeFee }(sendParam, fee, payable(from));

        verifyPackets(HOME_EID, addressToBytes32(address(adapter)));
    }
}
