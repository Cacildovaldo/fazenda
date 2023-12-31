// SPDX-License-Identifier: -- WISE --

pragma solidity =0.8.21;

import "https://github.com/Cacildovaldo/fazenda/blob/main/wstETHFarmMathLogic.sol";

abstract contract wstETHFarmLeverageLogic is
    wstETHFarmMathLogic,
    IFlashLoanRecipient
{
    /**
     * @dev Wrapper function preparing balancer flashloan and
     * loading data to pass into receiver.
     */
    function _executeBalancerFlashLoan(
        uint256 _nftId,
        uint256 _amount,
        uint256 _initialAmount,
        uint256 _lendingShares,
        uint256 _borrowShares,
        uint256 _minAmountOut,
        bool _ethBack
    )
        internal
    {
        bytes memory data = abi.encode(
            _nftId,
            _initialAmount,
            _lendingShares,
            _borrowShares,
            _minAmountOut,
            msg.sender,
            _ethBack
        );

        globalTokens.push(
            WETH
        );

        globalAmounts.push(
            _amount
        );

        allowEnter = true;

        BALANCER_VAULT.flashLoan(
            this,
            globalTokens,
            globalAmounts,
            data
        );

        globalTokens.pop();
        globalAmounts.pop();
    }

    /**
     * @dev Receive function from balancer flashloan. Body
     * is called from balancer at the end of their {flashLoan()}
     * logic. Overwritten with opening flows.
     */
    function receiveFlashLoan(
        IERC20[] memory _flashloanToken,
        uint256[] memory _amounts,
        uint256[] memory _feeAmounts,
        bytes memory _userData
    )
        external
    {
        if (allowEnter == false) {
            revert AccessDenied();
        }

        allowEnter = false;

        if (_flashloanToken.length == 0) {
            revert InvalidParam();
        }

        if (msg.sender != BALANCER_ADDRESS) {
            revert NotBalancerVault();
        }

        uint256 flashloanAmount = _amounts[0];

        uint256 totalDebtBalancer = flashloanAmount
            + _feeAmounts[0];

        (
            uint256 nftId,
            uint256 initialAmount,
            uint256 lendingShares,
            uint256 borrowShares,
            uint256 minOutAmount,
            address caller,
            bool ethBack

        ) = abi.decode(
            _userData,
            (
                uint256,
                uint256,
                uint256,
                uint256,
                uint256,
                address,
                bool
            )
        );

        if (initialAmount == 0) {
            _logicClosePosition(
                nftId,
                borrowShares,
                lendingShares,
                totalDebtBalancer,
                minOutAmount,
                caller,
                ethBack
            );

            return;
        }

        _logicOpenPosition(
            nftId,
            flashloanAmount + initialAmount,
            totalDebtBalancer
        );
    }

    /**
     * @dev Core logic for closing a position using balancer
     * flashloans.
     */
    function _logicClosePosition(
        uint256 _nftId,
        uint256 _borrowShares,
        uint256 _lendingShares,
        uint256 _totalDebtBalancer,
        uint256 _minOutAmount,
        address _caller,
        bool _ethBack
    )
        internal
    {
        AAVE_HUB.paybackExactShares(
            _nftId,
            WETH_ADDRESS,
            _borrowShares
        );

        uint256 withdrawAmount = WISE_LENDING.withdrawExactShares(
            _nftId,
            WST_ETH_ADDRESS,
            _lendingShares
        );

        uint256 stETHAmount = WST_ETH.unwrap(
            withdrawAmount
        );

        uint256 ethAmount = _swapStETHintoETH(
            stETHAmount,
            _minOutAmount
        );

        if (_ethBack == true) {

            _closingRouteETH(
                ethAmount,
                _totalDebtBalancer,
                _caller
            );

            return;
        }

        _closingRouteWETH(
            ethAmount,
            _totalDebtBalancer,
            _caller
        );
    }

    /**
     * @dev Internal wrapper function for a closing route
     * which returns WETH to the owner in the end.
     */
    function _closingRouteWETH(
        uint256 _ethAmount,
        uint256 _totalDebtBalancer,
        address _caller
    )
        internal
    {
        _wrapETH(
            _ethAmount
        );

        _safeTransfer(
            WETH_ADDRESS,
            msg.sender,
            _totalDebtBalancer
        );

        _safeTransfer(
            WETH_ADDRESS,
            _caller,
            _ethAmount - _totalDebtBalancer
        );
    }

    /**
     * @dev Internal wrapper function for a closing route
     * which returns ETH to the owner in the end.
     */
    function _closingRouteETH(
        uint256 _ethAmount,
        uint256 _totalDebtBalancer,
        address _caller
    )
        internal
    {
        _wrapETH(
            _totalDebtBalancer
        );

        _safeTransfer(
            WETH_ADDRESS,
            msg.sender,
            _totalDebtBalancer
        );

        payable(_caller).transfer(
            _ethAmount - _totalDebtBalancer
        );
    }

    /**
     * @dev Internal wrapper function for curve swap
     * of stETH into ETH.
     */
    function _swapStETHintoETH(
        uint256 _swapAmount,
        uint256 _minOutAmount
    )
        internal
        returns (uint256)
    {
        return CURVE.exchange(
            {
                fromIndex: 1,
                toIndex: 0,
                exactAmountFrom: _swapAmount,
                minReceiveAmount: _minOutAmount
            }
        );
    }

    /**
     * @dev Internal function executing the
     * collateral deposit by converting ETH
     * into wstETH, adding it as collateral and
     * borrowing the flashloan token (WETH) to pay
     * back {_totalDebtBalancer}.
     */
    function _logicOpenPosition(
        uint256 _nftId,
        uint256 _depositAmount,
        uint256 _totalDebtBalancer
    )
        internal
    {
        _unwrapETH(
            _depositAmount
        );

        uint256 stETHShares = ST_ETH.submit{
            value: _depositAmount
        }(
            referralAddress
        );

        uint256 stETHAmount = ST_ETH.getPooledEthByShares(
            stETHShares
        );

        uint256 wstETHAmount = WST_ETH.wrap(
            stETHAmount
        );

        WISE_LENDING.depositExactAmount(
            _nftId,
            WST_ETH_ADDRESS,
            wstETHAmount
        );

        AAVE_HUB.borrowExactAmount(
            _nftId,
            WETH_ADDRESS,
            _totalDebtBalancer
        );

        if (_checkDebtRatio(_nftId) == false) {
            revert DebtRatioTooHigh();
        }

        _safeTransfer(
            WETH_ADDRESS,
            BALANCER_ADDRESS,
            _totalDebtBalancer
        );
    }

    /**
     * @dev Internal function summarizing liquidation
     * checks and interface call for core liquidation
     * from wise lending.
     */
    function _coreLiquidation(
        uint256 _nftId,
        uint256 _nftIdLiquidator,
        uint256 _shareAmountToPay
    )
        internal
        returns (
            uint256 paybackAmount,
            uint256 receivingAmount
        )
    {
        if (_checkDebtRatio(_nftId) == true) {
            revert DebtRatioTooLow();
        }

        paybackAmount = WISE_LENDING.paybackAmount(
            AAVE_WETH_ADDRESS,
            _shareAmountToPay
        );

        receivingAmount = WISE_LENDING.coreLiquidationIsolationPools(
            _nftId,
            _nftIdLiquidator,
            msg.sender,
            msg.sender,
            AAVE_WETH_ADDRESS,
            WST_ETH_ADDRESS,
            paybackAmount,
            _shareAmountToPay
        );
    }
}
