// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@oz/access/Ownable.sol";

contract GuardianPause is Ownable {
    address public guardian;
    bool public paused = false;

    event EmergencyPaused(uint256 timestamp);
    event EmergencyUnpaused(uint256 timestamp);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    constructor(address _guardian) Ownable(msg.sender) {
        require(_guardian != address(0), "Invalid guardian address");
        guardian = _guardian;
    }

    modifier onlyGuardian() {
        require(msg.sender == guardian, "Not guardian");
        _;
    }

    modifier whenNotPaused() virtual {
        require(!paused, "Contract paused");
        _;
    }

    function setGuardian(address _guardian) external onlyOwner {
        require(_guardian != address(0), "Invalid guardian address");
        address oldGuardian = guardian;
        guardian = _guardian;
        emit GuardianUpdated(oldGuardian, _guardian);
    }

    function emergencyPause() external onlyGuardian {
        paused = true;
        emit EmergencyPaused(block.timestamp);
    }

    function emergencyUnpause() external onlyGuardian {
        paused = false;
        emit EmergencyUnpaused(block.timestamp);
    }

    function isPaused() external view returns (bool) {
        return paused;
    }
}
