// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.24 <0.9.0;

import {IStakingManager} from "src/interfaces/IStakingManager.sol";

/// @notice Storage struct for a FIFO queue of validator KeyStores.
struct Queue {
    mapping(uint256 index => IStakingManager.KeyStore keyStore) keyStores;
    uint128 first;
    uint128 last;
}

/// @title QueueLib
/// @notice FIFO queue implementation for validator key management.
/// @author Olla Core contributors
library QueueLib {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when attempting to dequeue from an empty queue.
    error QueueLib__QueueIsEmpty();

    /// @notice Thrown when accessing an invalid queue index.
    error QueueLib__QueueIndexOutOfBounds();

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the queue with first and last set to 1.
    /// @param _self The queue storage reference.
    function init(Queue storage _self) internal {
        _self.first = 1;
        _self.last = 1;
    }

    /// @notice Adds a KeyStore to the back of the queue.
    /// @param _self The queue storage reference.
    /// @param _keyStore The KeyStore to add.
    /// @return queueLocation The index where the KeyStore was stored.
    function enqueue(Queue storage _self, IStakingManager.KeyStore memory _keyStore)
        internal
        returns (uint128 queueLocation)
    {
        queueLocation = _self.last;
        _self.keyStores[queueLocation] = _keyStore;
        _self.last = queueLocation + 1;
        return queueLocation;
    }

    /// @notice Removes and returns the KeyStore from the front of the queue.
    /// @param _self The queue storage reference.
    /// @return keyStore The dequeued KeyStore.
    function dequeue(Queue storage _self) internal returns (IStakingManager.KeyStore memory keyStore) {
        if (_self.last <= _self.first) {
            revert QueueLib__QueueIsEmpty();
        }
        keyStore = _self.keyStores[_self.first];
        delete _self.keyStores[_self.first];
        ++_self.first;
        return keyStore;
    }

    /// @notice Returns the number of KeyStores in the queue.
    /// @param _self The queue storage reference.
    /// @return The queue length.
    function length(Queue storage _self) internal view returns (uint128) {
        return _self.last - _self.first;
    }

    /// @notice Returns the first index of the queue.
    /// @param _self The queue storage reference.
    /// @return The first index.
    function getFirstIndex(Queue storage _self) internal view returns (uint128) {
        return _self.first;
    }

    /// @notice Returns the last index of the queue.
    /// @param _self The queue storage reference.
    /// @return The last index.
    function getLastIndex(Queue storage _self) internal view returns (uint128) {
        return _self.last;
    }

    /// @notice Returns the KeyStore at a specific index.
    /// @param _self The queue storage reference.
    /// @param _index The index to retrieve.
    /// @return The KeyStore at the index.
    function getValueAtIndex(Queue storage _self, uint128 _index)
        internal
        view
        returns (IStakingManager.KeyStore memory)
    {
        if (_index < _self.first || _index >= _self.last) {
            revert QueueLib__QueueIndexOutOfBounds();
        }
        return _self.keyStores[_index];
    }
}
