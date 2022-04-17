// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./ERC677Receiver.sol";
import "./Ledger.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract BondExchange is BoringOwnable, ERC677Receiver, ReentrancyGuard {
    using SafeMath for uint256;
    using Address for address;
    using SafeERC20 for ERC20;

    ERC20 public bond;
    Ledger public ledger;

    address[] public erc677Tokens;

    address public fundsAdmin;

    event FundsAdminChanged(address _fundsAdmin);

    constructor(address _bond, address _ledger, address _fundsAdmin, address[] memory _erc677Tokens) public {
        require(_bond.isContract() && _ledger.isContract() && _fundsAdmin != address(0), "BondExchange: invalid parameter");

        bond = ERC20(_bond);
        ledger = Ledger(_ledger);
        erc677Tokens = _erc677Tokens;
    }

    function setFundsAdmin(address _fundsAdmin) external onlyOwner {
        require(_fundsAdmin != address(0), "BondExchange: invalid parameter");
        fundsAdmin = _fundsAdmin;
        emit FundsAdminChanged(_fundsAdmin);
    }

    function onTokenTransfer(address _from, uint256 _value, bytes calldata _data) external override nonReentrant returns (bool) {
        _data;
        address token = msg.sender;
        require(isAccept677Token(token), "BondExchange: caller is not accepted 677 token");

        uint256 balance = bond.balanceOf(address(this));
        uint256 tokenDecimals = ERC20(token).decimals();
        uint256 bondDecimals = bond.decimals();

        uint256 valueToBond = _value.mul(10 ** bondDecimals).div(10 ** tokenDecimals);

        if (valueToBond <= balance) {
            bond.safeTransfer(_from, valueToBond);
        } else {
            bond.safeTransfer(_from, balance);
            ERC20(token).safeTransfer(_from, valueToBond.sub(balance).mul(10 ** tokenDecimals).div(10 ** bondDecimals));
        }

        ERC20(token).safeTransfer(fundsAdmin, ERC20(token).balanceOf(address(this)));
        return true;
    }

    function debtToBond(uint256 amountInUSD) external returns (uint256) {
        uint256 amount = ledger.debtToBond(msg.sender, amountInUSD);
        if (amount > 0) {
            uint256 decimals = bond.decimals();
            uint256 bondAmount = amount.mul(10 ** decimals).div(1e8);
            require(bondAmount <= bond.balanceOf(address(this)), "BondExchange: bond is not enough");
            bond.safeTransfer(msg.sender, bondAmount);
        }

        return amount;
    }

    function isAccept677Token(address _token) public view returns(bool) {
        for(uint8 i = 0; i < erc677Tokens.length; i++) {
            if (erc677Tokens[i] == _token) return true;
        }

        return false;
    }

    function withdraw(address _token, address _to, uint256 _amount) external onlyOwner returns (uint256) {
        uint256 balance = ERC20(_token).balanceOf(address(this));
        _amount = _amount >= balance ? balance : _amount;
        ERC20(_token).safeTransfer(_to, _amount);
        return _amount;
    }

    function getERC677TokenLength() external view returns (uint256) {
        return erc677Tokens.length;
    }
}
