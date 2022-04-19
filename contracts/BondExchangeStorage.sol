// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract BondExchangeStorage {
    ERC20 public bond;
    address public ledger;

    address[] public erc677Tokens;

    address public fundsAdmin;
}
