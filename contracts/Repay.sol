// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./Ledger.sol";

contract Repay is BoringOwnable {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;
    using Address for address;

    mapping(address => mapping(address => uint256)) repaidMap;

    Ledger public ledger;
    address[] public repayFTokens;

    address public fBTC;
    address public fETH;

    event Repaid(address indexed _account, uint256 _ftokenAmount, uint256 _exchangeRate, uint256 _repayInUSD);

    constructor (address _ledger, address[] memory _repayFTokens, address _fBTC, address _fETH) public {
        require(_ledger.isContract() && _fBTC.isContract() && _fETH.isContract(), "Repay: invalid parameter");

        ledger = Ledger(_ledger);
        repayFTokens = _repayFTokens;
        fBTC = _fBTC;
        fETH = _fETH;
    }

    function prices(address _token) public view returns (uint256) {
        return ledger.prices(_token);
    }

    function getDebtTokens() external view returns (address[] memory) {
        return ledger.getDebtTokens();
    }

    function getRepayFTokens() external view returns (address[] memory) {
        address[] memory ftokens = new address[](repayFTokens.length + 2);

        ftokens[0] = fBTC;
        ftokens[1] = fETH;
        for (uint8 i = 0; i < repayFTokens.length; i++) {
            ftokens[i + 2] = repayFTokens[i];
        }

        return ftokens;
    }

    function getAccountDebt(address _account) public view returns (uint256[] memory) {
        return ledger.getAccountDebt(_account);
    }

    function getAccountRepaid(address _account) external view returns (uint256[] memory) {
        uint256[] memory repaidAmounts = new uint256[](repayFTokens.length + 3);

        repaidAmounts[0] = repaidMap[_account][fBTC];
        repaidAmounts[1] = repaidMap[_account][fETH];

        for (uint8 i = 0; i < repayFTokens.length; i++) {
            repaidAmounts[i + 2] = repaidMap[_account][repayFTokens[i]];
        }

        // get bond amount
        uint256[] memory ledgerRepaid = ledger.getAccountRepaid(_account);
        repaidAmounts[repaidAmounts.length - 1] = ledgerRepaid[ledgerRepaid.length - 1];

        return repaidAmounts;
    }

    function getAccountDebtInUSD(address _account) public view returns (uint256 debtInUSD) {
        return ledger.getAccountDebtInUSD(_account);
    }

    function getAccountRepaidInUSD(address _account) public returns (uint256 repaidInUSD) {
        if (repaidMap[_account][fBTC] != 0) {
            repaidInUSD = repaidInUSD.add(getFTokenUSD(fBTC, repaidMap[_account][fBTC]));
        }

        if (repaidMap[_account][fETH] != 0) {
            repaidInUSD = repaidInUSD.add(getFTokenUSD(fETH, repaidMap[_account][fETH]));
        }

        for (uint8 i = 0; i < repayFTokens.length; i++) {
            if (repaidMap[_account][repayFTokens[i]] == 0) continue;
            repaidInUSD = repaidInUSD.add(getFTokenUSD(repayFTokens[i], repaidMap[_account][repayFTokens[i]]));
        }

        repaidInUSD = repaidInUSD.add(ledger.getAccountRepaidInUSD(_account));
    }

    function repayBTCToUsers(address[] memory _accounts, uint256[] memory _repayAmount) external onlyOwner {
        require(_accounts.length == _repayAmount.length, "Repay: invalid parameter");

        for (uint8 i = 0; i < _accounts.length; i++) {
            repayToUserByAmount(fBTC, _accounts[i], _repayAmount[i]);
        }
    }

    function repayETHToUsers(address[] memory _accounts, uint256[] memory _repayAmount) external onlyOwner {
        require(_accounts.length == _repayAmount.length, "Repay: invalid parameter");

        for (uint8 i = 0; i < _accounts.length; i++) {
            repayToUserByAmount(fETH, _accounts[i], _repayAmount[i]);
        }
    }

    function repayUSDTokenToUsers(address _ftoken, address[] memory _accounts, uint256[] memory _repayAmount) external onlyOwner {
        require(_accounts.length == _repayAmount.length, "Repay: invalid parameter");
        require(ftokenExist(_ftoken), "Repay: ftoken not exist in repayFTokens");

        for (uint8 i = 0; i < _accounts.length; i++) {
            repayToUserByAmount(_ftoken, _accounts[i], _repayAmount[i]);
        }
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

    function repayToUserByAmount(address _ftoken, address _account, uint256 _amount) internal {
        uint256 debtInUSD = getAccountDebtInUSD(_account);
        uint256 repaidInUSD = getAccountRepaidInUSD(_account);
        if (debtInUSD <= repaidInUSD) {
            return;
        }

        uint8 index = getDebtIndex(_ftoken);
        if (index == uint8(-1)) return;

        uint256 debtAmount = getAccountDebt(_account)[index];
        if (debtAmount == 0) return;

        RepayLocalParam memory vars;
        vars.balance = CErc20(_ftoken).balanceOf(address(this));
        if (vars.balance == 0) return;

        vars.underlying = CErc20(_ftoken).underlying();
        vars.decimals = ERC20(vars.underlying).decimals();
        vars.exchangedRate = CErc20(_ftoken).exchangeRateCurrent();

        uint256 repaidAmount = repaidMap[_account][_ftoken] == 0 ?
                    repaidMap[_account][_ftoken] :
                    vars.exchangedRate.mul(repaidMap[_account][_ftoken]).div(1e18);
        if (repaidAmount >= debtAmount) return;

        if (_amount >  debtAmount.sub(repaidAmount)) {
            _amount = debtAmount.sub(repaidAmount);
        }

        uint256 repayInUSD = _amount.mul(prices(vars.underlying)).div(10 ** vars.decimals);
        if (repayInUSD > debtInUSD.sub(repaidInUSD)) {
            repayInUSD = debtInUSD.sub(repaidInUSD);
            _amount = repayInUSD.mul(10 ** vars.decimals).div(prices(vars.underlying));
        }

        vars.ftokenAmount = _amount.mul(1e18).div(vars.exchangedRate);
        if (vars.ftokenAmount > vars.balance) {
            vars.ftokenAmount = vars.balance;
        }
        // save to repaid map.
        repaidMap[_account][_ftoken] = repaidMap[_account][_ftoken].add(vars.ftokenAmount);

        // transfer ftoken to user.
        ERC20(_ftoken).safeTransfer(_account, vars.ftokenAmount);
        emit Repaid(_account, vars.ftokenAmount, vars.exchangedRate, repayInUSD);

        // check repaid in usd.
        debtInUSD = getAccountDebtInUSD(_account);
        repaidInUSD = getAccountRepaidInUSD(_account);
        require(debtInUSD >= repaidInUSD, "Repay: repay error");
    }

    function repayToUsers(address[] memory _accounts, uint256[] memory _repayInUSD) external onlyOwner {
        require(_accounts.length == _repayInUSD.length, "Repay: invalid parameter");

        for (uint8 i = 0; i < _accounts.length; i++) {
            repayToUser(_accounts[i], _repayInUSD[i]);
        }
    }

    function repayToUser(address _account, uint256 _repayInUSD) internal {
        uint256 debtInUSD = getAccountDebtInUSD(_account);
        uint256 repaidInUSD = getAccountRepaidInUSD(_account);
        if (debtInUSD <= repaidInUSD) {
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
            vars.underlyingInUSD = vars.exchangedRate.mul(vars.balance).div(1e18).mul(prices(vars.underlying)).div(10 ** vars.decimals);

            if (repayCurrentInUSD <= vars.underlyingInUSD) {
                vars.ftokenAmount = repayCurrentInUSD.mul(10 ** vars.decimals).div(prices(vars.underlying)).mul(1e18).div(vars.exchangedRate);
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
        require(debtInUSD >= repaidInUSD, "Repay: repay error");
    }

    function getFTokenUSD(address _ftoken, uint256 _amount) internal returns(uint256) {
        address underlying = CErc20(_ftoken).underlying();
        uint256 decimals = ERC20(underlying).decimals();
        uint256 underlyingAmount = CErc20(_ftoken).exchangeRateCurrent().mul(_amount).div(1e18);

        return underlyingAmount.mul(prices(underlying)).div(10 ** decimals);
    }

    function getDebtIndex(address _ftoken) internal view returns (uint8) {
        address underlying = CErc20(_ftoken).underlying();
        address[] memory debtTokens = ledger.getDebtTokens();
        uint8 index = uint8(-1);
        for (uint8 i = 0; i < debtTokens.length; i++) {
            if (underlying != debtTokens[i]) continue;
            index = i;
            break;
        }
        return index;
    }


    function withdraw(address _token, address _to, uint256 _amount) external onlyOwner returns (uint256) {
        uint256 balance = ERC20(_token).balanceOf(address(this));
        _amount = _amount >= balance ? balance : _amount;
        ERC20(_token).safeTransfer(_to, _amount);
        return _amount;
    }

    function ftokenExist(address _ftoken) private view returns (bool) {
        for (uint8 i = 0; i < repayFTokens.length; i++) {
            if (_ftoken == repayFTokens[i]) return true;
        }

        return false;
    }
}
