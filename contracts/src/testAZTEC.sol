//SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@oz/token/ERC20/ERC20.sol";

contract testAZTEC is ERC20 {
    constructor() ERC20("testAZTEC", "tAZTEC") { }

    // Minting is open to anyone and for free.
    // You can implement your custom logic to mint tokens.
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
