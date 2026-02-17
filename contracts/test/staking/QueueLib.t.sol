// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { Queue, QueueLib } from "src/staking/libraries/QueueLib.sol";
import { IStakingManager } from "src/staking/interfaces/IStakingManager.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";

/*//////////////////////////////////////////////////////////////
                    QUEUELIB FUZZ TEST
//////////////////////////////////////////////////////////////*/

/// @title QueueLibWrapper
/// @notice Thin storage wrapper that exposes QueueLib methods for testing.
contract QueueLibWrapper {
    using QueueLib for Queue;

    Queue internal _queue;

    constructor() {
        _queue.init();
    }

    function enqueue(IStakingManager.KeyStore memory keyStore) external returns (uint128) {
        return _queue.enqueue(keyStore);
    }

    function dequeue() external returns (IStakingManager.KeyStore memory) {
        return _queue.dequeue();
    }

    function length() external view returns (uint128) {
        return _queue.length();
    }

    function getFirstIndex() external view returns (uint128) {
        return _queue.getFirstIndex();
    }

    function getLastIndex() external view returns (uint128) {
        return _queue.getLastIndex();
    }

    function getValueAtIndex(uint128 index) external view returns (IStakingManager.KeyStore memory) {
        return _queue.getValueAtIndex(index);
    }
}

/// @title QueueLibTest
/// @notice Unit and fuzz tests for the QueueLib FIFO queue implementation.
contract QueueLibTest is Test {
    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    QueueLibWrapper internal queue;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        queue = new QueueLibWrapper();
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Builds a deterministic KeyStore from a seed value.
    function _makeKeyStore(uint256 seed) internal pure returns (IStakingManager.KeyStore memory keyStore) {
        keyStore = IStakingManager.KeyStore({
            attester: address(uint160(uint256(keccak256(abi.encodePacked("attester", seed))))),
            publicKeyG1: G1Point({
                x: uint256(keccak256(abi.encodePacked("g1x", seed))),
                y: uint256(keccak256(abi.encodePacked("g1y", seed)))
            }),
            publicKeyG2: G2Point({
                x0: uint256(keccak256(abi.encodePacked("g2x0", seed))),
                x1: uint256(keccak256(abi.encodePacked("g2x1", seed))),
                y0: uint256(keccak256(abi.encodePacked("g2y0", seed))),
                y1: uint256(keccak256(abi.encodePacked("g2y1", seed)))
            }),
            proofOfPossession: G1Point({
                x: uint256(keccak256(abi.encodePacked("popx", seed))),
                y: uint256(keccak256(abi.encodePacked("popy", seed)))
            })
        });
    }

    /*//////////////////////////////////////////////////////////////
                           BASIC UNIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_InitialState() external view {
        assertEq(queue.length(), 0, "initial length should be zero");
        assertEq(queue.getFirstIndex(), 1, "initial first index should be 1");
        assertEq(queue.getLastIndex(), 1, "initial last index should be 1");
    }

    function test_EnqueueIncrementsLength() external {
        IStakingManager.KeyStore memory ks = _makeKeyStore(1);
        queue.enqueue(ks);

        assertEq(queue.length(), 1, "length should be 1 after enqueue");
    }

    function test_DequeueDecrementsLength() external {
        IStakingManager.KeyStore memory ks = _makeKeyStore(1);
        queue.enqueue(ks);
        queue.dequeue();

        assertEq(queue.length(), 0, "length should be 0 after dequeue");
    }

    function test_DequeueReturnsCorrectElement() external {
        IStakingManager.KeyStore memory ks = _makeKeyStore(42);
        queue.enqueue(ks);
        IStakingManager.KeyStore memory dequeued = queue.dequeue();

        assertEq(dequeued.attester, ks.attester, "dequeued attester should match enqueued");
    }

    function test_DequeueEmptyReverts() external {
        vm.expectRevert(QueueLib.QueueLib__QueueIsEmpty.selector);
        queue.dequeue();
    }

    function test_GetValueAtIndex_OutOfBounds_Reverts() external {
        IStakingManager.KeyStore memory ks = _makeKeyStore(1);
        queue.enqueue(ks);

        vm.expectRevert(QueueLib.QueueLib__QueueIndexOutOfBounds.selector);
        queue.getValueAtIndex(0);

        vm.expectRevert(QueueLib.QueueLib__QueueIndexOutOfBounds.selector);
        queue.getValueAtIndex(2);
    }

    function test_GetValueAtIndex_Valid() external {
        IStakingManager.KeyStore memory ks = _makeKeyStore(7);
        queue.enqueue(ks);

        IStakingManager.KeyStore memory fetched = queue.getValueAtIndex(1);
        assertEq(fetched.attester, ks.attester, "getValueAtIndex should return correct element");
    }

    function test_FIFOOrdering_ThreeElements() external {
        IStakingManager.KeyStore memory ks1 = _makeKeyStore(1);
        IStakingManager.KeyStore memory ks2 = _makeKeyStore(2);
        IStakingManager.KeyStore memory ks3 = _makeKeyStore(3);

        queue.enqueue(ks1);
        queue.enqueue(ks2);
        queue.enqueue(ks3);

        assertEq(queue.length(), 3, "length should be 3");

        IStakingManager.KeyStore memory d1 = queue.dequeue();
        assertEq(d1.attester, ks1.attester, "first dequeue should return first enqueued");

        IStakingManager.KeyStore memory d2 = queue.dequeue();
        assertEq(d2.attester, ks2.attester, "second dequeue should return second enqueued");

        IStakingManager.KeyStore memory d3 = queue.dequeue();
        assertEq(d3.attester, ks3.attester, "third dequeue should return third enqueued");

        assertEq(queue.length(), 0, "length should be 0 after all dequeues");
    }

    /*//////////////////////////////////////////////////////////////
                           FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzzes enqueue then dequeue sequences, asserting FIFO ordering, correct length,
    ///         and that an empty dequeue reverts.
    function testFuzz_EnqueueDequeueSequence(uint8 enqueueCountRaw, uint8 dequeueCountRaw) external {
        uint256 enqueueCount = bound(enqueueCountRaw, 1, 50);
        uint256 dequeueCount = bound(dequeueCountRaw, 1, enqueueCount);

        address[] memory expectedAttesters = new address[](enqueueCount);
        for (uint256 i = 0; i < enqueueCount; i++) {
            IStakingManager.KeyStore memory ks = _makeKeyStore(i);
            expectedAttesters[i] = ks.attester;
            uint128 location = queue.enqueue(ks);

            assertEq(location, uint128(i + 1), "enqueue location should be sequential");
        }

        assertEq(queue.length(), uint128(enqueueCount), "length should equal enqueue count");

        for (uint256 i = 0; i < dequeueCount; i++) {
            IStakingManager.KeyStore memory dequeued = queue.dequeue();
            assertEq(dequeued.attester, expectedAttesters[i], "FIFO order must be preserved");
        }

        uint256 expectedRemaining = enqueueCount - dequeueCount;
        assertEq(queue.length(), uint128(expectedRemaining), "length should reflect remaining items");

        if (expectedRemaining == 0) {
            vm.expectRevert(QueueLib.QueueLib__QueueIsEmpty.selector);
            queue.dequeue();
        }
    }

    /// @notice Fuzzes interleaved enqueue/dequeue patterns and checks length consistency.
    function testFuzz_InterleavedOperations(uint8 ops) external {
        uint256 opCount = bound(ops, 1, 80);

        uint256 enqueuedTotal;
        uint256 dequeuedTotal;

        for (uint256 i = 0; i < opCount; i++) {
            bool doEnqueue = (i % 3 != 2) || (enqueuedTotal == dequeuedTotal);

            if (doEnqueue) {
                IStakingManager.KeyStore memory ks = _makeKeyStore(i + 1000);
                queue.enqueue(ks);
                enqueuedTotal++;
            } else {
                if (enqueuedTotal > dequeuedTotal) {
                    queue.dequeue();
                    dequeuedTotal++;
                } else {
                    IStakingManager.KeyStore memory ks = _makeKeyStore(i + 2000);
                    queue.enqueue(ks);
                    enqueuedTotal++;
                }
            }

            assertEq(
                queue.length(),
                uint128(enqueuedTotal - dequeuedTotal),
                "length must equal enqueued minus dequeued at every step"
            );
        }
    }

    /// @notice Fuzz test that getValueAtIndex returns the correct element for in-range indices.
    function testFuzz_GetValueAtIndex(uint8 countRaw, uint8 indexOffsetRaw) external {
        uint256 count = bound(countRaw, 1, 50);

        address[] memory expectedAttesters = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            IStakingManager.KeyStore memory ks = _makeKeyStore(i + 5000);
            expectedAttesters[i] = ks.attester;
            queue.enqueue(ks);
        }

        uint256 indexOffset = bound(indexOffsetRaw, 0, count - 1);
        uint128 queryIndex = queue.getFirstIndex() + uint128(indexOffset);

        IStakingManager.KeyStore memory fetched = queue.getValueAtIndex(queryIndex);
        assertEq(fetched.attester, expectedAttesters[indexOffset], "getValueAtIndex should return correct element");
    }
}
