// SPDX-License-Identifier: MIT

pragma solidity ^0.8.1;

import "./BaseStrategy.sol";
import "./HedgehogCoreStrategyConfig.sol";

// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.8.13;

import "./IFarmMasterChef.sol";
import "./SafeERC20";

abstract contract HedgeHogCoreStrategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    event DebtRebalance(
        uint256 debtRatio,
        uint256 swapAmount,
        uint256 slippage
    );
    event CollatRebalance(uint256 collatRatio, uint256 adjAmount);

    uint256 public stratLendAllocation;
    uint256 public stratDebtAllocation;
    uint256 public collatUpper = 6700;
    uint256 public collatTarget = 6000;
    uint256 public collatLower = 5300;
    uint256 public debtUpper = 10200;
    uint256 public debtLower = 9800;
    uint256 public rebalancePercent = 10000; // 100% (how far does rebalance of debt move towards 100% from threshold)

    // protocal limits & upper, target and lower thresholds for ratio of debt to collateral
    uint256 public collatLimit = 7500;

    // ERC20 Tokens;
    IERC20 public short;
    IUniswapV2Pair wantShortLP; // This is public because it helps with unit testing
    IERC20 farmTokenLP;
    IERC20 farmToken;
    IERC20 compToken;

    // Contract Interfaces
    ICTokenErc20 cTokenLend;
    ICTokenErc20 cTokenBorrow;
    IFarmMasterChef farm;
    IUniswapV2Router01 router;
    IComptroller comptroller;
    IPriceOracle oracle;
    IStrategyInsurance public insurance;

    uint256 public slippageAdj = 9900; // 99%
    uint256 public slippageAdjHigh = 10100; // 101%

    uint256 constant BASIS_PRECISION = 10000;
    uint256 constant STD_PRECISION = 1e18;
    uint256 farmPid;
    address weth;

    constructor(address _vault, CoreStrategyConfig memory _config)
        public
        BaseStrategy(_vault)
    {
        // config = _config;
        farmPid = _config.farmPid;

        // initialise token interfaces
        short = IERC20(_config.short);
        wantShortLP = IUniswapV2Pair(_config.wantShortLP);
        farmTokenLP = IERC20(_config.farmTokenLP);
        farmToken = IERC20(_config.farmToken);
        compToken = IERC20(_config.compToken);

        // initialise other interfaces
        cTokenLend = ICTokenErc20(_config.cTokenLend);
        cTokenBorrow = ICTokenErc20(_config.cTokenBorrow);
        farm = IFarmMasterChef(_config.farmMasterChef);
        router = IUniswapV2Router01(_config.router);
        comptroller = IComptroller(_config.comptroller);
        weth = router.WETH();

        enterMarket();
        _updateLendAndDebtAllocation();

        maxReportDelay = 7200;
        minReportDelay = 3600;
        profitFactor = 1500;
        debtThreshold = 1_000_000 * 1e18;
    }

    function _updateLendAndDebtAllocation() internal {
        stratLendAllocation = 
            BASIS_PRECISION * BASIS_PRECISION
            / (BASIS_PRECISION + collatTarget);
        stratDebtAllocation = BASIS_PRECISION - stratLendAllocation;
    }

    function name() external view override returns (string memory) {
        return "StrategyHedgedFarming";
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // We might need to return want to the vault
        //uint256 liquidate = _debtOutstanding;

        uint256 totalAssets = estimatedTotalAssets();
        uint256 totalDebt = _getTotalDebt();
        if (totalAssets > totalDebt) {
            _profit = totalAssets - totalDebt;
            (uint256 amountFreed, ) =
                liquidatePosition(_debtOutstanding + _profit);
            if (_debtOutstanding > amountFreed) {
                _debtPayment = amountFreed;
                _profit = 0;
            } else {
                _debtPayment = _debtOutstanding;
                _profit = amountFreed - _debtOutstanding;
            }
            _loss = 0;
        } else {
            _loss = totalDebt - totalAssets;
            _loss -= (insurance.reportLoss(totalDebt, _profit));
        }

        if (balancePendingHarvest() > 100) {
            _profit += _harvestInternal();

            // process insurance
            uint256 insurancePayment =
                insurance.reportProfit(totalDebt, _profit);

            // double check insurance isn't asking for too much or zero
            if (insurancePayment > 0 && insurancePayment < _profit) {
                SafeERC20.safeTransfer(
                    want,
                    address(insurance),
                    insurancePayment
                );
                _profit = _profit - insurancePayment;
            }
        }
    }

    function returnDebtOutstanding(uint256 _debtOutstanding)
        public
        returns (uint256 _debtPayment, uint256 _loss)
    {
        // We might need to return want to the vault
        if (_debtOutstanding > 0) {
            uint256 _amountFreed = 0;
            (_amountFreed, _loss) = liquidatePosition(_debtOutstanding);
            _debtPayment = Math.min(_amountFreed, _debtOutstanding);
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _wantAvailable = balanceOfWant();
        if (_debtOutstanding >= _wantAvailable) {
            return;
        }
        uint256 toInvest = _wantAvailable - _debtOutstanding;
        if (toInvest > 0) {
            _deploy(toInvest);
        }
    }

    function prepareMigration(address _newStrategy) internal override {
        liquidateAllPositionsInternal();
    }

    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return
            address(want) == address(weth)
                ? _amtInWei
                : quote(weth, address(want), _amtInWei);
    }

    function quote(
        address _in,
        address _out,
        uint256 _amtIn
    ) internal view returns (uint256) {
        address[] memory path = getTokenOutPath(_in, _out);
        return router.getAmountsOut(_amtIn, path)[path.length - 1];
    }

    function getTokenOutPath(address _token_in, address _token_out)
        internal
        view
        returns (address[] memory _path)
    {
        bool is_weth =
            _token_in == address(weth) || _token_out == address(weth);
        _path = new address[](is_weth ? 2 : 3);
        _path[0] = _token_in;
        if (is_weth) {
            _path[1] = _token_out;
        } else {
            _path[1] = address(weth);
            _path[2] = _token_out;
        }
    }

    function approveContracts() external virtual onlyGovernance {
        want.safeApprove(address(cTokenLend), uint256(-1));
        short.safeApprove(address(cTokenBorrow), uint256(-1));
        want.safeApprove(address(router), uint256(-1));
        short.safeApprove(address(router), uint256(-1));
        farmToken.safeApprove(address(router), uint256(-1));
        compToken.safeApprove(address(router), uint256(-1));
        IERC20(address(wantShortLP)).safeApprove(address(router), uint256(-1));
        IERC20(address(wantShortLP)).safeApprove(address(farm), uint256(-1));
    }

    function resetApprovals() external virtual onlyGovernance {
        want.safeApprove(address(cTokenLend), 0);
        short.safeApprove(address(cTokenBorrow), 0);
        want.safeApprove(address(router), 0);
        short.safeApprove(address(router), 0);
        farmToken.safeApprove(address(router), 0);
        compToken.safeApprove(address(router), 0);
        IERC20(address(wantShortLP)).safeApprove(address(router), 0);
        IERC20(address(wantShortLP)).safeApprove(address(farm), 0);
    }

    function setSlippageAdj(uint256 _lower, uint256 _upper)
        external
        onlyAuthorized
    {
        slippageAdj = _lower;
        slippageAdjHigh = _upper;
    }

    // Can only be set once.
    function setInsurance(address _insurance) external onlyGovernance {
        require(address(insurance) == address(0));
        insurance = IStrategyInsurance(_insurance);
    }

    function setDebtThresholds(
        uint256 _lower,
        uint256 _upper,
        uint256 _rebalancePercent
    ) external onlyAuthorized {
        require(_lower <= BASIS_PRECISION);
        require(_rebalancePercent <= BASIS_PRECISION);
        require(_upper >= BASIS_PRECISION);
        rebalancePercent = _rebalancePercent;
        debtUpper = _upper;
        debtLower = _lower;
    }

    function setCollateralThresholds(
        uint256 _lower,
        uint256 _target,
        uint256 _upper,
        uint256 _limit
    ) external onlyAuthorized {
        require(_limit <= BASIS_PRECISION);
        collatLimit = _limit;
        require(collatLimit > _upper);
        require(_upper >= _target);
        require(_target >= _lower);
        collatUpper = _upper;
        collatTarget = _target;
        collatLower = _lower;
        _updateLendAndDebtAllocation();
    }

    function liquidateAllToLend() internal {
        _withdrawAllFromFarm();
        _removeAllLp();
        _repayDebt();
        _lendWant(balanceOfWant());
    }

    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        (_amountFreed, ) = liquidateAllPositionsInternal();
    }

    function liquidateAllPositionsInternal()
        internal
        returns (uint256 _amountFreed, uint256 _loss)
    {
        _withdrawAllFromFarm();
        _removeAllLp();

        uint256 debtInShort = balanceDebtInShort();
        uint256 balShort = balanceShort();
        if (balShort >= debtInShort) {
            _repayDebt();
            if (balanceShortWantEq() > 0) {
                (, _loss) = _swapExactShortWant(short.balanceOf(address(this)));
            }
        } else {
            uint256 debtDifference = debtInShort- balShort;
            if (convertShortToWantLP(debtDifference) > 0) {
                (_loss) = _swapWantShortExact(debtDifference);
            } else {
                _swapExactWantShort(uint256(1));
            }
            _repayDebt();
        }

        _redeemWant(balanceLend());
        _amountFreed = balanceOfWant();
    }

    /// rebalances RoboVault strat position to within target collateral range
    function rebalanceCollateral() external onlyKeepers {
        // ratio of amount borrowed to collateral
        uint256 collatRatio = calcCollateral();
        require(collatRatio <= collatLower || collatRatio >= collatUpper);
        _rebalanceCollateralInternal();
    }

    /// rebalances RoboVault holding of short token vs LP to within target collateral range
    function rebalanceDebt() external onlyKeepers {
        uint256 debtRatio = calcDebtRatio();
        require(debtRatio < debtLower || debtRatio > debtUpper);
        _rebalanceDebtInternal();
    }

    function claimHarvest() internal virtual {
        farm.withdraw(farmPid, 0); /// for spooky swap call withdraw with amt = 0
    }

    /// called by keeper to harvest rewards and either repay debt
    function _harvestInternal() internal returns (uint256 _wantHarvested) {
        uint256 wantBefore = balanceOfWant();
        /// harvest from farm & wantd on amt borrowed vs LP value either -> repay some debt or add to collateral
        claimHarvest();
        comptroller.claimComp(address(this));
        _sellHarvestForWant();
        _sellCompForWant();
        _wantHarvested = balanceOfWant() - wantBefore);
    }

    /**
     * Checks if collateral cap is reached or if deploying `_amount` will make it reach the cap
     * returns true if the cap is reached
     */
    function collateralCapReached(uint256 _amount)
        public
        view
        virtual
        returns (bool)
    {
        return cTokenLend.totalCollateralTokens() + _amount < cTokenLend.collateralCap();
    }

    function _rebalanceCollateralInternal() internal {
        uint256 collatRatio = calcCollateral();
        uint256 shortPos = balanceDebt();
        uint256 lendPos = balanceLendCollateral();

        if (collatRatio > collatTarget) {
            uint256 adjAmount = (shortPos - (lendPos * collatTarget) / BASIS_PRECISION)
                * (BASIS_PRECISION / (BASIS_PRECISION + collatTarget));
            /// remove some LP use 50% of withdrawn LP to repay debt and half to add to collateral
            _withdrawLpRebalanceCollateral(adjAmount * 2);
            emit CollatRebalance(collatRatio, adjAmount);
        } else if (collatRatio < collatTarget) {
            //Borrows ajdAmount more Short and withdraws the same amount in want
            uint256 adjAmount = (lendPos * collatTarget / BASIS_PRECISION - shortPos) 
                * (BASIS_PRECISION / (BASIS_PRECISION + collatTarget));
            uint256 borrowAmt = _borrowWantEq(adjAmount);
            _redeemWant(adjAmount);
            //creates LP and deposits it in the farm 
            _addToLP(borrowAmt);
            _depositAllLpInFarm();
            emit CollatRebalance(collatRatio, adjAmount);
        }
    }

    // deploy assets according to vault strategy
    function _deploy(uint256 _amount) internal {
        if (_amount < 10000) {
            return;
        }

        if (collateralCapReached(_amount)) {
            return;
        }

        uint256 lendDeposit = stratLendAllocation * _amount / BASIS_PRECISION;
        _lendWant(lendDeposit);
        uint256 borrowAmtWant = stratDebtAllocation * _amount / BASIS_PRECISION;
        uint256 borrowAmt = _borrowWantEq(borrowAmtWant);
        _addToLP(borrowAmt);
        _depositAllLpInFarm();
    }

    /**
     * @notice
     *  Assumes all balance is in Lend outside of a small amount of debt and short. Deploys
     *  capital maintaining the collatRatioTarget
     *
     *  @dev
     *  Some crafty maths here:
     *  T: _amount,       Lp = 1/2 Lp balance in Want,  L: Lend Balance in Want,
     *  D: Debt in Want,  Di: Initial Debt in Want,     C: Collateral Target     Si Initial Short in Want
     *
     *  T = L + D + 2Lp
     *  Lp = D + Si - Di
     *  D = C * L
     *
     *  Solving this for L finds:
     *  L = (T - 2Si + 2Di) / (1 + C)
     */
    function _deployFromLend(uint256 collatRatioTarget, uint256 _amount)
        internal
    {
        uint256 balanceShortInitial = balanceShort();
        uint256 balanceShortInitialInWant =
            convertShortToWantLP(balanceShortInitial);
        uint256 balanceDebtInitial = balanceDebtInShort();
        uint256 balanceDebtInitialInWant =
            convertShortToWantLP(balanceDebtInitial);
        uint256 lendNeeded =
            (_amount - (balanceShortInitialInWant * 2) - (balanceDebtInitialInWant * 2)
            ) * BASIS_PRECISION / (BASIS_PRECISION + collatRatioTarget);
        _redeemWant(balanceLend() - lendNeeded);
        uint256 borrowAmtShort =
            _borrowWantEq(
                (lendNeeded * collatRatioTarget / BASIS_PRECISION) - balanceDebtInitialInWant
            );
        _addToLP(borrowAmtShort + balanceShortInitial);
        _depositAllLpInFarm();
    }

    function _rebalanceDebtInternal() internal {
        uint256 swapAmountWant;
        uint256 slippage;
        uint256 debtRatio = calcDebtRatio();
        uint256 collatRatio = calcCollateral(); // We will rebalance to the same collat.

        // Liquidate all the lend, leaving some in debt or as short
        liquidateAllToLend();

        uint256 debtInShort = balanceDebtInShort();
        uint256 debt = convertShortToWantLP(debtInShort);
        uint256 balShort = balanceShort();

        if (debtInShort > balShort) {
            // If there's excess debt, we swap some want to repay a portion of the debt
            swapAmountWant = debt * rebalancePercent / BASIS_PRECISION;
            _redeemWant(swapAmountWant);
            slippage = _swapExactWantShort(swapAmountWant);
            _repayDebt();
        } else {
            // If there's excess short, we swap some to want which will be used
            // to create lp in _deployFromLend()
            (swapAmountWant, slippage) = _swapExactShortWant(balanceShort() * rebalancePercent / BASIS_PRECISION);
        }

        _deployFromLend(collatRatio, estimatedTotalAssets());
        emit DebtRebalance(debtRatio, swapAmountWant, slippage);
    }

    /**
     * Withdraws and removes `_deployedPercent` percentage if LP from farming and pool respectively
     *
     * @param _deployedPercent percentage multiplied by BASIS_PRECISION of LP to remove.
     */
    function _removeLpPercent(uint256 _deployedPercent) internal {
        uint256 lpPooled = countLpPooled();
        uint256 lpUnpooled = wantShortLP.balanceOf(address(this));
        uint256 lpCount = lpUnpooled + lpPooled;
        uint256 lpReq = lpCount * _deployedPercent / BASIS_PRECISION;
        uint256 lpWithdraw;
        if (lpReq - lpUnpooled < lpPooled) {
            lpWithdraw = lpReq - lpUnpooled;
        } else {
            lpWithdraw = lpPooled;
        }

        // Finally withdraw the LP from farms and remove from pool
        _withdrawAmountFromFarm(lpWithdraw);
        _removeAllLp();
    }

    function _getTotalDebt() internal view returns (uint256) {
        return vault.strategies(address(this)).totalDebt;
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`
        uint256 balanceWant = balanceOfWant();
        uint256 totalAssets = estimatedTotalAssets();

        // if estimatedTotalAssets is less than params.debtRatio it means there's
        // been a loss (ignores pending harvests). This type of loss is calculated
        // proportionally
        // This stops a run-on-the-bank if there's IL between harvests.
        uint256 totalDebt = _getTotalDebt();
        if (totalDebt > totalAssets) {
            uint256 ratio = totalAssets * STD_PRECISION * totalDebt;
            uint256 newAmount = _amountNeeded * ratio / STD_PRECISION;
            _loss = _amountNeeded - newAmount;
        }

        if (_amountNeeded > balanceWant) {
            uint256 amountToWithdraw =
                Math.min(totalAssets, _amountNeeded - balanceWant);
            (, _loss) = _withdraw(amountToWithdraw);
        }

        // Since we might free more than needed, let's send back the min
        _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded) - _loss;
    }

    /**
     * function to remove funds from strategy when users withdraws funds in excess of reserves
     *
     * withdraw takes the following steps:
     * 1. Removes _amountNeeded worth of LP from the farms and pool
     * 2. Uses the short removed to repay debt (Swaps short or base for large withdrawals)
     * 3. Redeems the
     * @param _amountNeeded `want` amount to liquidate
     */
    function _withdraw(uint256 _amountNeeded)
        internal
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 balanceWant = balanceOfWant();
        uint256 balanceDeployed = balanceDeployed();
        uint256 collatRatio = calcCollateral();

        // stratPercent: Percentage of the deployed capital we want to liquidate.
        uint256 stratPercent =
            (_amountNeeded - balanceWant) * BASIS_PRECISION) / balanceDeployed;

        if (stratPercent > 9500) {
            // Very much an edge-case. If this happened, we just undeploy the lot
            // and it'll be redeployed during the next harvest.
            (_liquidatedAmount, _loss) = liquidateAllPositionsInternal();
            _liquidatedAmount = Math.min(_liquidatedAmount, _amountNeeded);
            // _loss = loss;
        } else {
            // liquidate all to lend
            liquidateAllToLend();

            // Only rebalance if more than 5% is being liquidated
            // to save on gas
            uint256 slippage = 0;
            if (stratPercent > 500) {
                // swap to ensure the debt ratio isn't negatively affected
                uint256 debt = balanceDebt();
                if (balanceDebt() > 0) {
                    uint256 swapAmountWant =
                        debt * stratPercent / BASIS_PRECISION;
                    _redeemWant(swapAmountWant);
                    slippage = _swapExactWantShort(swapAmountWant);
                    _repayDebt();
                } else {
                    (, slippage) = _swapExactShortWant(balanceShort() * stratPercent / BASIS_PRECISION);
                }
            }

            // Redeploy the strat
            _deployFromLend(
                collatRatio,
                balanceDeployed - _amountNeeded - slippage
            );
            _liquidatedAmount = balanceOfWant() - balanceWant;
            _loss = slippage;
        }
    }

    function enterMarket() internal onlyAuthorized {
        address[] memory cTokens = new address[](1);
        cTokens[0] = address(cTokenLend);
        comptroller.enterMarkets(cTokens);
    }

    function exitMarket() internal onlyAuthorized {
        comptroller.exitMarket(address(cTokenLend));
    }

    /**
     * This method is often farm specific so it needs to be declared elsewhere.
     */
    function _farmPendingRewards(uint256 _pid, address _user)
        internal
        view
        virtual
        returns (uint256);

    // calculate total value of vault assets
    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant() + balanceDeployed();
    }

    // calculate total value of deployed assets
    function balanceDeployed() public view returns (uint256) {
        return balanceLend() + balanceLp() + balanceShortWantEq() - balanceDebt();
    }

    // debt ratio - used to trigger rebalancing of debt
    function calcDebtRatio() public view returns (uint256) {
        return balanceDebt() * BASIS_PRECISION * 2 / balanceLp();
    }

    // calculate debt / collateral - used to trigger rebalancing of debt & collateral
    function calcCollateral() public view returns (uint256) {
        return balanceDebtOracle() * BASIS_PRECISION / balanceLendCollateral();
    }

    function getLpReserves()
        internal
        view
        returns (uint256 _wantInLp, uint256 _shortInLp)
    {
        (uint112 reserves0, uint112 reserves1, ) = wantShortLP.getReserves();
        if (wantShortLP.token0() == address(want)) {
            _wantInLp = uint256(reserves0);
            _shortInLp = uint256(reserves1);
        } else {
            _wantInLp = uint256(reserves1);
            _shortInLp = uint256(reserves0);
        }
    }

    function convertShortToWantLP(uint256 _amountShort)
        internal
        view
        returns (uint256)
    {
        (uint256 wantInLp, uint256 shortInLp) = getLpReserves();
        return _amountShort * wantInLp / shortInLp;
    }

    function convertShortToWantOracle(uint256 _amountShort)
        internal
        view
        returns (uint256)
    {
        return _amountShort * oracle.getPrice() / 1e18;
    }

    function convertWantToShortLP(uint256 _amountWant)
        internal
        view
        returns (uint256)
    {
        (uint256 wantInLp, uint256 shortInLp) = getLpReserves();
        return _amountWant * shortInLp / wantInLp;
    }

    function balanceLpInShort() public view returns (uint256) {
        return countLpPooled() + wantShortLP.balanceOf(address(this));
    }

    /// get value of all LP in want currency
    function balanceLp() public view returns (uint256) {
        (uint256 wantInLp, ) = getLpReserves();
        return balanceLpInShort() * wantInLp) * 2 / wantShortLP.totalSupply();
    }

    // value of borrowed tokens in value of short tokens
    function balanceDebtInShort() public view returns (uint256) {
        return cTokenBorrow.borrowBalanceStored(address(this));
    }

    // value of borrowed tokens in value of want tokens
    function balanceDebt() public view returns (uint256) {
        return convertShortToWantLP(balanceDebtInShort());
    }

    /**
     * Debt balance using price oracle
     */
    function balanceDebtOracle() public view returns (uint256) {
        return convertShortToWantOracle(balanceDebtInShort());
    }

    function balancePendingHarvest() public view returns (uint256) {
        uint256 rewardsPending = _farmPendingRewards(farmPid, address(this)) + farmToken.balanceOf(address(this)));
        uint256 harvestLP_A = _getHarvestInHarvestLp();
        uint256 shortLP_A = _getShortInHarvestLp();
        (uint256 wantLP_B, uint256 shortLP_B) = getLpReserves();

        uint256 balShort = rewardsPending * shortLP_A / harvestLP_A;
        uint256 balRewards = balShort * wantLP_B / shortLP_B;
        return (balRewards);
    }

    // reserves
    function balanceOfWant() public view returns (uint256) {
        return (want.balanceOf(address(this)));
    }

    function balanceShort() public view returns (uint256) {
        return (short.balanceOf(address(this)));
    }

    function balanceShortWantEq() public view returns (uint256) {
        return (convertShortToWantLP(short.balanceOf(address(this))));
    }

    function balanceLend() public view returns (uint256) {
        return cTokenLend.balanceOf(address(this)) * cTokenLend.exchangeRateStored() / 1e18;
    }

    function balanceLendCollateral() public view virtual returns (uint256) {
        return cTokenLend.accountCollateralTokens(address(this)) * cTokenLend.exchangeRateStored() / 1e18;
    }

    function getWantInLending() internal view returns (uint256) {
        return want.balanceOf(address(cTokenLend));
    }

    function countLpPooled() internal view virtual returns (uint256) {
        return farm.userInfo(farmPid, address(this)).amount;
    }

    // lend want tokens to lending platform
    function _lendWant(uint256 amount) internal {
        cTokenLend.mint(amount);
    }

    // borrow tokens woth _amount of want tokens
    function _borrowWantEq(uint256 _amount)
        internal
        returns (uint256 _borrowamount)
    {
        _borrowamount = convertWantToShortLP(_amount);
        _borrow(_borrowamount);
    }

    function _borrow(uint256 borrowAmount) internal {
        cTokenBorrow.borrow(borrowAmount);
    }

    // automatically repays debt using any short tokens held in wallet up to total debt value
    function _repayDebt() internal {
        uint256 _bal = short.balanceOf(address(this));
        if (_bal == 0) return;

        uint256 _debt = balanceDebtInShort();
        if (_bal < _debt) {
            cTokenBorrow.repayBorrow(_bal);
        } else {
            cTokenBorrow.repayBorrow(_debt);
        }
    }

    function _getHarvestInHarvestLp() internal view returns (uint256) {
        uint256 harvest_lp = farmToken.balanceOf(address(farmTokenLP));
        return harvest_lp;
    }

    function _getShortInHarvestLp() internal view returns (uint256) {
        uint256 shortToken_lp = short.balanceOf(address(farmTokenLP));
        return shortToken_lp;
    }

    function _redeemWant(uint256 _redeem_amount) internal {
        cTokenLend.redeemUnderlying(_redeem_amount);
    }

    // withdraws some LP worth _amount, converts all withdrawn LP to short token to repay debt
    function _withdrawLpRebalance(uint256 _amount)
        internal
        returns (uint256 swapAmountWant, uint256 slippageWant)
    {
        uint256 lpUnpooled = wantShortLP.balanceOf(address(this));
        uint256 lpPooled = countLpPooled();
        uint256 lpCount = lpUnpooled + lpPooled;
        uint256 lpReq = _amount * lpCount / balanceLp();
        uint256 lpWithdraw;
        if (lpReq - lpUnpooled < lpPooled) {
            lpWithdraw = lpReq - lpUnpooled;
        } else {
            lpWithdraw = lpPooled;
        }
        _withdrawAmountFromFarm(lpWithdraw);
        _removeAllLp();
        swapAmountWant = Math.min(
            _amount / 2,
            want.balanceOf(address(this))
        );
        slippageWant = _swapExactWantShort(swapAmountWant);

        _repayDebt();
    }

    //  withdraws some LP worth _amount, uses withdrawn LP to add to collateral & repay debt
    function _withdrawLpRebalanceCollateral(uint256 _amount) internal {
        uint256 lpUnpooled = wantShortLP.balanceOf(address(this));
        uint256 lpPooled = countLpPooled();
        uint256 lpCount = lpUnpooled lpPooled;
        uint256 lpReq = _amount * lpCount / balanceLp();
        uint256 lpWithdraw;
        if (lpReq - lpUnpooled < lpPooled) {
            lpWithdraw = lpReq - lpUnpooled;
        } else {
            lpWithdraw = lpPooled;
        }
        _withdrawAmountFromFarm(lpWithdraw);
        _removeAllLp();

        uint256 wantBal = balanceOfWant();
        if (_amount / 2 <= wantBal) {
            _lendWant(_amount / 2);
        } else {
            _lendWant(wantBal);
        }
        _repayDebt();
    }

    function _addToLP(uint256 _amountShort) internal {
        uint256 _amountWant = convertShortToWantLP(_amountShort);

        uint256 balWant = want.balanceOf(address(this));
        if (balWant < _amountWant) {
            _amountWant = balWant;
        }

        router.addLiquidity(
            address(short),
            address(want),
            _amountShort,
            _amountWant,
            _amountShort * slippageAdj / BASIS_PRECISION,
            _amountWant * slippageAdj / BASIS_PRECISION,
            address(this),
            now
        );
    }

    function _depositAllLpInFarm() internal virtual {
        uint256 lpBalance = wantShortLP.balanceOf(address(this)); /// get number of LP tokens
        farm.deposit(farmPid, lpBalance); /// deposit LP tokens to farm
    }

    function _withdrawAmountFromFarm(uint256 _amount) internal virtual {
        require(_amount <= countLpPooled());
        farm.withdraw(farmPid, _amount);
    }

    function _withdrawAllFromFarm() internal {
        farm.withdraw(farmPid, countLpPooled());    
    }

    // all LP currently not in Farm is removed.
    function _removeAllLp() internal {
        uint256 _amount = wantShortLP.balanceOf(address(this));
        (uint256 wantLP, uint256 shortLP) = getLpReserves();
        uint256 lpIssued = wantShortLP.totalSupply();

        uint256 amountAMin =
            ((_amount * shortLP * slippageAdj) / BASIS_PRECISION) / lpIssued;
        uint256 amountBMin =
            ((_amount * wantLP * slippageAdj) / BASIS_PRECISION) / lpIssued;
        router.removeLiquidity(
            address(short),
            address(want),
            _amount,
            amountAMin,
            amountBMin,
            address(this),
            now
        );
    }

    function _sellHarvestForWant() internal virtual {
        uint256 harvestBalance = farmToken.balanceOf(address(this));
        if (harvestBalance == 0) return;
        router.swapExactTokensForTokens(
            harvestBalance,
            0,
            getTokenOutPath(address(farmToken), address(want)),
            address(this),
            now
        );
    }

    /**
     * Harvest comp token from the lending platform and swap for the want token
     */
    function _sellCompForWant() internal virtual {
        uint256 compBalance = compToken.balanceOf(address(this));
        if (compBalance == 0) return;
        router.swapExactTokensForTokens(
            compBalance,
            0,
            getTokenOutPath(address(compToken), address(want)),
            address(this),
            now
        );
    }

    /**
     * @notice
     *  Swaps _amount of want for short
     *
     * @param _amount The amount of want to swap
     *
     * @return slippageWant Returns the cost of fees + slippage in want
     */
    function _swapExactWantShort(uint256 _amount)
        internal
        returns (uint256 slippageWant)
    {
        uint256 amountOutMin = convertWantToShortLP(_amount);
        uint256[] memory amounts =
            router.swapExactTokensForTokens(
                _amount,
                amountOutMin * slippageAdj / BASIS_PRECISION,
                getTokenOutPath(address(want), address(short)), // _pathWantToShort(),
                address(this),
                now
            );
        slippageWant = convertShortToWantLP(amountOutMin - amounts[amounts.length - 1]));
    }

    /**
     * @notice
     *  Swaps _amount of short for want
     *
     * @param _amountShort The amount of short to swap
     *
     * @return _amountWant Returns the want amount minus fees
     * @return _slippageWant Returns the cost of fees + slippage in want
     */
    function _swapExactShortWant(uint256 _amountShort)
        internal
        returns (uint256 _amountWant, uint256 _slippageWant)
    {
        _amountWant = convertShortToWantLP(_amountShort);
        uint256[] memory amounts =
            router.swapExactTokensForTokens(
                _amountShort,
                _amountWant * slippageAdj / BASIS_PRECISION),
                getTokenOutPath(address(short), address(want)),
                address(this),
                now
            );
        _slippageWant = _amountWant - amounts[amounts.length - 1];
    }

    function _swapWantShortExact(uint256 _amountOut)
        internal
        returns (uint256 _slippageWant)
    {
        uint256 amountInWant = convertShortToWantLP(_amountOut);
        uint256 amountInMax =
            (amountInWant * slippageAdjHigh / BASIS_PRECISION) + 1; // add 1 to make up for rounding down
        uint256[] memory amounts =
            router.swapTokensForExactTokens(
                _amountOut,
                amountInMax,
                getTokenOutPath(address(want), address(short)),
                address(this),
                now
            );
        _slippageWant = amounts[0] - amountInWant;
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        // TODO - Fit this into the contract somehow
        address[] memory protected = new address[](7);
        protected[0] = address(short);
        protected[1] = address(wantShortLP);
        protected[2] = address(farmToken);
        protected[3] = address(farmTokenLP);
        protected[4] = address(compToken);
        protected[5] = address(cTokenLend);
        protected[6] = address(cTokenBorrow);
        return protected;
    }
}