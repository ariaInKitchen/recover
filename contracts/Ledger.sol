// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./BoringOwnable.sol";
import "./compound/CErc20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Ledger is BoringOwnable {
    using SafeMath for uint256;

    uint256 constant PRICE_FACTOR = 1e8;

    mapping(address => mapping(address => uint256)) arrearsMap;
    mapping(address => mapping(address => uint256)) repaidMap;

    mapping(address => uint256) public prices; // the price in USD, multiplied by 1e8

    address[] public arrearsTokens;
    address[] public repayFTokens;

    event TokenPriceChanged(address indexed _token, uint256 _price);
    event Repaid(address indexed _account, bool _succeeded, uint256 _repayInUSD);

    constructor (address[] memory _arrearsTokens, address[] memory _repayFTokens) public {
        arrearsTokens = _arrearsTokens;
        repayFTokens = _repayFTokens;
    }

    function setPrice(address[] memory _tokens, uint256[] memory _prices) external onlyOwner {
        require(_tokens.length == _prices.length, "Ledger: invalid parameter");

        for (uint8 i = 0; i < _tokens.length; i++) {
            prices[_tokens[i]] = _prices[i];
            emit TokenPriceChanged(_tokens[i], _prices[i]);
        }
    }

    function repayToUsers(address[] memory _accounts, uint256[] memory _repayInUSD) external onlyOwner {
        require(_accounts.length == _repayInUSD.length, "Ledger: invalid parameter");

        for (uint8 i = 0; i < _accounts.length; i++) {
            (bool succeeded, uint256 repaid) = repayToUser(_accounts[i], _repayInUSD[i]);
            emit Repaid(_accounts[i], succeeded, repaid);
        }
    }

    function withdrawFToken(address _ftoken, uint256 _amount) external onlyOwner returns (uint256) {
        uint256 balance = ERC20(_ftoken).balanceOf(address(this));
        _amount = _amount >= balance ? balance : _amount;
        ERC20(_ftoken).transfer(owner, _amount);
        return _amount;
    }

    function getAccountArrears(address _account) external view returns (uint256[] memory) {
        uint256[] memory arrearsAmount = new uint256[](arrearsTokens.length);

        for (uint8 i = 0; i < arrearsTokens.length; i++) {
            arrearsAmount[i] = arrearsMap[_account][arrearsTokens[i]];
        }

        return arrearsAmount;
    }

    function getAccountRepaid(address _account) external view returns (uint256[] memory) {
        uint256[] memory repaidAomount = new uint256[](repayFTokens.length);

        for (uint8 i = 0; i < repayFTokens.length; i++) {
            repaidAomount[i] = repaidMap[_account][repayFTokens[i]];
        }

        return repaidAomount;
    }

    function getAccountArrearsInUSD(address _account) public view returns (uint256 arrearsInUSD) {
        for (uint8 i = 0; i < arrearsTokens.length; i++) {
            if (arrearsMap[_account][arrearsTokens[i]] == 0) continue;
            uint256 decimals = ERC20(arrearsTokens[i]).decimals();
            arrearsInUSD = arrearsInUSD.add(arrearsMap[_account][arrearsTokens[i]].mul(prices[arrearsTokens[i]]).div(10 ** decimals));
        }
    }

    function getAccountRepaidInUSD(address _account) public returns (uint256 repaidInUSD) {
        for (uint8 i = 0; i < repayFTokens.length; i++) {
            if (repaidMap[_account][repayFTokens[i]] == 0) continue;

            address underlying = CErc20(repayFTokens[i]).underlying();
            uint256 decimals = ERC20(underlying).decimals();
            uint256 underlyingAmount = CErc20(repayFTokens[i]).exchangeRateCurrent().mul(repaidMap[_account][repayFTokens[i]]).div(1e18);

            repaidInUSD = repaidInUSD.add(underlyingAmount.mul(prices[underlying]).div(10 ** decimals));
        }
    }

    struct RepayLocalParam {
        uint256 balance;
        address underlying;
        uint256 decimals;
        uint256 exchangedRate;
        uint256 underlyingInUSD;
        uint256 ftokenAmount;
    }

    function repayToUser(address _account, uint256 _repayInUSD) internal returns (bool, uint256) {
        uint256 arrearsInUSD = getAccountArrearsInUSD(_account);
        uint256 repaidInUSD = getAccountRepaidInUSD(_account);
        require(arrearsInUSD >= repaidInUSD, "Ledger: user repaid is bigeer than arrears");

        uint256 repayCurrentInUSD = _repayInUSD > arrearsInUSD.sub(repaidInUSD) ? arrearsInUSD.sub(repaidInUSD) : _repayInUSD;
        if (repayCurrentInUSD == 0) {
            return (false, repayCurrentInUSD);
        }

        uint repaidCurrentInUSD = 0;
        for (uint8 i = 0; i < repayFTokens.length; i++) {
            RepayLocalParam memory vars;
            vars.balance = CErc20(repayFTokens[i]).balanceOf(address(this));
            if (vars.balance == 0) continue;

            vars.underlying = CErc20(repayFTokens[i]).underlying();
            vars.decimals = ERC20(vars.underlying).decimals();
            vars.exchangedRate = CErc20(repayFTokens[i]).exchangeRateCurrent();
            vars.underlyingInUSD = vars.exchangedRate.mul(vars.balance).div(1e18).mul(prices[vars.underlying]).div(10 ** vars.decimals);

            if (repayCurrentInUSD <= vars.underlyingInUSD) {
                vars.ftokenAmount = repayCurrentInUSD.mul(10 ** vars.decimals).div(prices[vars.underlying]).mul(1e18).div(vars.exchangedRate);
                repaidCurrentInUSD = repaidCurrentInUSD.add(repayCurrentInUSD);
                repayCurrentInUSD = 0;
            } else {
                vars.ftokenAmount = vars.balance;
                repayCurrentInUSD = repayCurrentInUSD.sub(vars.underlyingInUSD);
                repaidCurrentInUSD = repaidCurrentInUSD.add(vars.underlyingInUSD);
            }
            // save to repaid map.
            repaidMap[_account][repayFTokens[i]] = repaidMap[_account][repayFTokens[i]].add(vars.ftokenAmount);

            // transfer ftoken to user.
            ERC20(repayFTokens[i]).transfer(_account, vars.ftokenAmount);

            if (repayCurrentInUSD == 0) break;
        }

        // check repaid in usd.
        arrearsInUSD = getAccountArrearsInUSD(_account);
        repaidInUSD = getAccountRepaidInUSD(_account);
        require(arrearsInUSD >= repaidInUSD, "Ledger: repay error");

        return (true, repaidCurrentInUSD);
    }
}
