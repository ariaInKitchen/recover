// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./BoringOwnable.sol";
import "./compound/CErc20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

contract Ledger is BoringOwnable {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;
    using Address for address;

    uint256 constant PRICE_FACTOR = 1e8;

    mapping(address => mapping(address => uint256)) debtMap;
    mapping(address => mapping(address => uint256)) repaidMap;
    mapping(address => uint256) bondMap;

    mapping(address => uint256) totalDebtMap;
    mapping(address => uint256) public totalDebtAccount;

    uint256 public totalBond;
    uint256 public totalBondAccount;

    mapping(address => uint256) public prices; // the price in USD, multiplied by 1e8

    address[] public debtTokens;
    address[] public repayFTokens;

    address public bondExchange;

    modifier onlyBondExchange() {
        require(msg.sender == bondExchange, "Ledger: onlyBondExchange");
        _;
    }

    event TokenPriceChanged(address indexed _token, uint256 _price);
    event Repaid(address indexed _account, uint256 _ftokenAmount, uint256 _exchangeRate, uint256 _repayInUSD);
    event UserDebtChanged(address indexed _account, address _token, uint256 _amount);
    event BondExchangeChanged(address _bondExchange);
    event DebtToBondSuccess(address _account, uint256 _amountInUSD);

    constructor (address[] memory _debtTokens, address[] memory _repayFTokens) public {
        debtTokens = _debtTokens;
        repayFTokens = _repayFTokens;
    }

    function setPrice(address[] memory _tokens, uint256[] memory _prices) external onlyOwner {
        require(_tokens.length == _prices.length, "Ledger: invalid parameter");

        for (uint8 i = 0; i < _tokens.length; i++) {
            prices[_tokens[i]] = _prices[i];
            emit TokenPriceChanged(_tokens[i], _prices[i]);
        }
    }

    function setDebts(address _token, address[] memory _accounts, uint256[] memory _amounts) external onlyOwner {
        require(tokenExist(_token) && _accounts.length == _amounts.length, "Ledger: invalid parameter");

        for (uint8 i = 0; i < _accounts.length; i++) {
            require(_accounts[i] != address(0), "Ledger: token is not exist");

            if (debtMap[_accounts[i]][_token] != 0) {
                totalDebtMap[_token] = totalDebtMap[_token].sub(debtMap[_accounts[i]][_token]);
            } else {
                totalDebtAccount[_token] += 1;
            }
            totalDebtMap[_token] = totalDebtMap[_token].add(_amounts[i]);

            debtMap[_accounts[i]][_token] = _amounts[i];
            emit UserDebtChanged(_accounts[i], _token, _amounts[i]);
        }
    }

    function setBondExchange(address _bondExchange) external onlyOwner {
        require(_bondExchange.isContract(), "Ledger: invalid parameter");

        bondExchange = _bondExchange;
        emit BondExchangeChanged(_bondExchange);
    }

    function repayToUsers(address[] memory _accounts, uint256[] memory _repayInUSD) external onlyOwner {
        require(_accounts.length == _repayInUSD.length, "Ledger: invalid parameter");

        for (uint8 i = 0; i < _accounts.length; i++) {
            repayToUser(_accounts[i], _repayInUSD[i]);
        }
    }

    function debtToBond(address _account, uint256 _amountInUSD) external onlyBondExchange returns (uint256) {
        uint256 debtInUSD = getAccountDebtInUSD(_account);
        uint256 repaidInUSD = getAccountRepaidInUSD(_account);
        require(debtInUSD >= repaidInUSD, "Ledger: user repaid is bigger than debt");

        _amountInUSD = _amountInUSD <= debtInUSD.sub(repaidInUSD) ? _amountInUSD : debtInUSD.sub(repaidInUSD);
        if (_amountInUSD == 0) return 0;

        if (bondMap[_account] == 0) {
            totalBondAccount++;
        }

        totalBond = totalBond.add(_amountInUSD);
        bondMap[_account] = bondMap[_account].add(_amountInUSD);
        emit DebtToBondSuccess(_account, _amountInUSD);

        return _amountInUSD;
    }

    function withdrawFToken(address _ftoken, uint256 _amount) external onlyOwner returns (uint256) {
        uint256 balance = ERC20(_ftoken).balanceOf(address(this));
        _amount = _amount >= balance ? balance : _amount;
        ERC20(_ftoken).safeTransfer(owner, _amount);
        return _amount;
    }

    function getDebtTokensLength() external view returns (uint256) {
        return debtTokens.length;
    }

    function getRepayFTokenLength() external view returns (uint256) {
        return repayFTokens.length;
    }

    function getAccountDebt(address _account) external view returns (uint256[] memory) {
        uint256[] memory debtAmounts = new uint256[](debtTokens.length);

        for (uint8 i = 0; i < debtTokens.length; i++) {
            debtAmounts[i] = debtMap[_account][debtTokens[i]];
        }

        return debtAmounts;
    }

    function getAccountRepaid(address _account) external view returns (uint256[] memory) {
        uint256[] memory repaidAmounts = new uint256[](repayFTokens.length);

        for (uint8 i = 0; i < repayFTokens.length; i++) {
            repaidAmounts[i] = repaidMap[_account][repayFTokens[i]];
        }

        return repaidAmounts;
    }

    function getAccountDebtInUSD(address _account) public view returns (uint256 debtInUSD) {
        for (uint8 i = 0; i < debtTokens.length; i++) {
            if (debtMap[_account][debtTokens[i]] == 0) continue;
            uint256 decimals = ERC20(debtTokens[i]).decimals();
            debtInUSD = debtInUSD.add(debtMap[_account][debtTokens[i]].mul(prices[debtTokens[i]]).div(10 ** decimals));
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

        repaidInUSD = repaidInUSD.add(bondMap[_account]);
    }

    function getTotalDebt(address _token) external view returns (uint256) {
        return totalDebtMap[_token];
    }

    function getTotalDebtInUSD(address _token) external view returns (uint256) {
        uint256 decimals = ERC20(_token).decimals();
        return totalDebtMap[_token].mul(prices[_token]).div(10 ** decimals);
    }

    struct RepayLocalParam {
        uint256 balance;
        address underlying;
        uint256 decimals;
        uint256 exchangedRate;
        uint256 underlyingInUSD;
        uint256 ftokenAmount;
        uint256 repaidInUSD;
    }

    function repayToUser(address _account, uint256 _repayInUSD) internal {
        uint256 debtInUSD = getAccountDebtInUSD(_account);
        uint256 repaidInUSD = getAccountRepaidInUSD(_account);
        if (debtInUSD < repaidInUSD) {
            return;
        }

        uint256 repayCurrentInUSD = _repayInUSD > debtInUSD.sub(repaidInUSD) ? debtInUSD.sub(repaidInUSD) : _repayInUSD;
        if (repayCurrentInUSD == 0) {
            return;
        }

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
                vars.repaidInUSD = repayCurrentInUSD;
                repayCurrentInUSD = 0;
            } else {
                vars.ftokenAmount = vars.balance;
                repayCurrentInUSD = repayCurrentInUSD.sub(vars.underlyingInUSD);
                vars.repaidInUSD = vars.underlyingInUSD;
            }
            // save to repaid map.
            repaidMap[_account][repayFTokens[i]] = repaidMap[_account][repayFTokens[i]].add(vars.ftokenAmount);

            // transfer ftoken to user.
            ERC20(repayFTokens[i]).safeTransfer(_account, vars.ftokenAmount);
            emit Repaid(_account, vars.ftokenAmount, vars.exchangedRate, vars.repaidInUSD);

            if (repayCurrentInUSD == 0) break;
        }

        // check repaid in usd.
        debtInUSD = getAccountDebtInUSD(_account);
        repaidInUSD = getAccountRepaidInUSD(_account);
        require(debtInUSD >= repaidInUSD, "Ledger: repay error");
    }

    function tokenExist(address _token) private view returns (bool) {
        for (uint8 i = 0; i < debtTokens.length; i++) {
            if (_token == debtTokens[i]) return true;
        }

        return false;
    }
}
