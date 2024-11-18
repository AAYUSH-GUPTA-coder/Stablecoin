// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

error DecentralizedStableCoin__MustBeMoreThanZero();
error DecentralizedStableCoin__BurnAmountExceedsBalance();
error DecentralizedStableCoin__NotZeroAddress();

/**
 * @title DecentralizedStableCoin
 * @author Aayush Gupta
 * Collateral : Exogenous ( ETH & BTC )
 * Minting : Algorithmic
 * Relative Stability : Pegged to USD
 *
 * This is the contract meant to be governed by the DSCEngine. This contract is just the ERC20 implementation of our stablecoin system.
 */

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) revert DecentralizedStableCoin__MustBeMoreThanZero();
        if (balance < _amount)
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        super.burn(_amount);
        // super is telling us, to use the burn function of the parent class.
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns(bool){
        if(_to == address(0)) revert DecentralizedStableCoin__NotZeroAddress();
        if(_amount <= 0) revert DecentralizedStableCoin__MustBeMoreThanZero();
        _mint(_to, _amount);
        return true;
    }
}
