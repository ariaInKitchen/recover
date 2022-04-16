// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface ERC677Receiver {
    function onTokenTransfer(address _from, uint256 _value, bytes calldata _data) external returns (bool);
}
