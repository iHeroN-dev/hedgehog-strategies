// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;
import "./BaseStrategy.sol";
import "./HedgehogCoreStrategyConfig.sol";
import "./Interfaces.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";


abstract contract HedgehogCoreStrategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    event DebtRebalance(
        uint256 debtRatio,
        uint256 swapAmount,
        uint256 slippage
    );
    event CollatRebalance(
        uint256 collatRatio, 
        uint256 adjAmount
    );
    
    bool public doPriceCheck = true;

    uint256 public collatUpper = 5500;
    uint256 public collatTarget = 5000;
    uint256 public collatLower = 4500;
    uint256 public debtUpper = 10200;
    uint256 public debtLower = 9800;
    uint256 public rebalancePercent = 10000; // 100% (how far does rebalance of debt move towards 100% from threshold)

    // protocol limits & upper, target and lower thresholds for ratio of debt to collateral
    uint256 public collatLimit = 7500;

    // ERC20 Tokens;
    IERC20 public short;
    IERC20 public wantEquivalent;
    IERC20 public shortEquivalent;
    IUniswapV2Pair farmingLP; // wantEquivalent-shortEquivalent pool
    IUniswapV2Pair wantShortLP; //want-short pool
    IUniswapV2Pair farmTokenLP; //LP to swap farmtoken -> short
    IUniswapV2Pair wantWantEquivalentLP;
    IUniswapV2Pair shortShortEquivalentLP;
    IERC20 farmToken;
    IERC20 compToken;

    // Contract Interfaces
    ICTokenErc20 cTokenLend;
    ICTokenErc20 cTokenBorrow;
    IFarmMasterChef farm;
    IUniswapV2Router01 router;
    IUniswapV2Router01 farmRouter;
    IComptroller comptroller;
    IPriceOracle oracle;
    IStrategyInsurance public insurance;

    uint256 public slippageAdj = 9900; // 99%

    uint256 constant BASIS_PRECISION = 10000;
    uint256 public priceSourceDiff = 500; // 5% Default
    uint256 constant STD_PRECISION = 1e18;
    uint256 farmPid;
    address weth;
    uint256 minDeploy;

    constructor(address _vault, HedgehogCoreStrategyConfig memory _config)
        public
        BaseStrategy(_vault)
    {
        // config = _config;
        farmPid = _config.farmPid;

        // initialise token interfaces
        short = IERC20(_config.short);
        shortEquivalent = IERC20(_config.shortEquivalent);
        wantEquivalent = IERC20(_config.wantEquivalent);
        farmingLP = IUniswapV2Pair(_config.farmingLP);
        wantShortLP = IUniswapV2Pair(_config.wantShortLP);
        farmTokenLP = IUniswapV2Pair(_config.farmTokenLP);
        farmToken = IERC20(_config.farmToken);
        compToken = IERC20(_config.compToken);

        // initialise other interfaces
        cTokenLend = ICTokenErc20(_config.cTokenLend);
        cTokenBorrow = ICTokenErc20(_config.cTokenBorrow);
        farm = IFarmMasterChef(_config.farmMasterChef);
        router = IUniswapV2Router01(_config.router);
        farmRouter = IUniswapV2Router01(_config.farmRouter);
        comptroller = IComptroller(_config.comptroller);
        weth = router.WETH();

        enterMarket();
        approveContracts();

        maxReportDelay = 7200;
        minReportDelay = 3600;
        profitFactor = 1500;
        minDeploy = _config.minDeploy;
    }

    
    function name() external view override returns (string memory) {
        return "HedgehogRiskyHedgedFarming";
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
        //Called by BaseStrategy.harvest() -> test price source
        require(_testPriceSource());
        uint256 totalAssets = estimatedTotalAssets();
        uint256 totalDebt = _getTotalDebt();
        if (totalAssets > totalDebt) {
            _profit = totalAssets.sub(totalDebt);
            (uint256 amountFreed, ) = _withdraw(_debtOutstanding.add(_profit));
            if (_debtOutstanding > amountFreed) {
                _debtPayment = amountFreed;
                _profit = 0;
            } else {
                _debtPayment = _debtOutstanding;
                _profit = amountFreed.sub(_debtOutstanding);
            }
        } else {
            _withdraw(_debtOutstanding);
            _debtPayment = balanceOfWant();
            _loss = totalDebt.sub(totalAssets);
        }

        if (balancePendingHarvest() > 100) {
            _profit = _profit.add(_harvestInternal());
        }

        // Check if we're net loss or net profit
        if (_loss >= _profit) {
            _profit = 0;
            _loss = _loss.sub(_profit);
            insurance.reportLoss(totalDebt, _loss);
        } else {
            _profit = _profit.sub(_loss);
            _loss = 0;
            uint256 insurancePayment =
                insurance.reportProfit(totalDebt, _profit);
            _profit = _profit.sub(insurancePayment);

            // double check insurance isn't asking for too much or zero
            if (insurancePayment > 0 && insurancePayment < _profit) {
                SafeERC20.safeTransfer(
                    want,
                    address(insurance),
                    insurancePayment
                );
            }
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        //Called by BaseStrategy.tend() -> test price source
        require(_testPriceSource());
        uint256 _wantAvailable = balanceOfWant();
        if (_debtOutstanding >= _wantAvailable) {
            return;
        }
        uint256 toInvest = _wantAvailable.sub(_debtOutstanding);
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
        override
        returns (uint256)
    {
        // This is not currently used by the strategies and is
        // being removed to reduce the size of the contract
        return 0;
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

    function approveContracts() internal {
        want.safeApprove(address(cTokenLend), uint256(-1));
        short.safeApprove(address(cTokenBorrow), uint256(-1));
        want.safeApprove(address(router), uint256(-1));
        short.safeApprove(address(router), uint256(-1));
        wantEquivalent.safeApprove(address(router), uint256(-1));
        shortEquivalent.safeApprove(address(router), uint256(-1));
        farmToken.safeApprove(address(router), uint256(-1));
        compToken.safeApprove(address(router), uint256(-1));
        wantEquivalent.safeApprove(address(farmRouter), uint256(-1));
        shortEquivalent.safeApprove(address(farmRouter), uint256(-1));
        IERC20(address(farmingLP)).safeApprove(address(farmRouter), uint256(-1));
        IERC20(address(farmingLP)).safeApprove(address(farm), uint256(-1));
    }

    function resetApprovals() external onlyEmergencyAuthorized{
        want.safeApprove(address(cTokenLend), uint256(0));
        short.safeApprove(address(cTokenBorrow), uint256(0));
        want.safeApprove(address(router), uint256(0));
        short.safeApprove(address(router), uint256(0));
        wantEquivalent.safeApprove(address(router), uint256(0));
        shortEquivalent.safeApprove(address(router), uint256(0));
        farmToken.safeApprove(address(router), uint256(0));
        compToken.safeApprove(address(router), uint256(0));
        wantEquivalent.safeApprove(address(farmRouter), uint256(0));
        shortEquivalent.safeApprove(address(farmRouter), uint256(0));
        IERC20(address(farmingLP)).safeApprove(address(farmRouter), uint256(0));
        IERC20(address(farmingLP)).safeApprove(address(farm), uint256(0));
    }

    function setSlippageConfig(
        uint256 _slippageAdj,
        uint256 _priceSourceDif,
        bool _doPriceCheck
    ) external onlyAuthorized {
        slippageAdj = _slippageAdj;
        priceSourceDiff = _priceSourceDif;
        doPriceCheck = _doPriceCheck;
    }
    //TODO INSURANCE? address 0? TODO Research:  It will revert if the insurance address is not 0? What?
    function setInsurance(address _insurance) external onlyAuthorized {
        require(address(insurance) == address(0));
        insurance = IStrategyInsurance(_insurance);
    }

    function migrateInsurance(address _newInsurance) external onlyGovernance {
        require(address(_newInsurance) == address(0));
        insurance.migrateInsurance(_newInsurance);
        insurance = IStrategyInsurance(_newInsurance);
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
    }

    function liquidatePositionAuth(uint256 _amount) external onlyAuthorized {
        require(_testPriceSource());
        liquidatePosition(_amount);
    }

    function liquidateAllToLend() internal {
        _withdrawAllPooled();
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
        _withdrawAllPooled();
        _removeAllLp();
        _cleanUpEquivalent();

        uint256 debtInShort = balanceDebtInShortCurrent();
        uint256 balShort = balanceShort();
        if (balShort >= debtInShort) {
            _repayDebt();
            if (balanceShortWantEq() > 0) {
                (, _loss) = _swapExactShortWant(short.balanceOf(address(this)));
            }
        } else {
            uint256 debtDifference = debtInShort - balShort;
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
        require(_testPriceSource());
        _rebalanceCollateralInternal();
    }

    /// rebalances RoboVault holding of short token vs LP to within target collateral range
    function rebalanceDebt() external onlyKeepers {
        uint256 debtRatio = calcDebtRatio();
        require(debtRatio < debtLower || debtRatio > debtUpper);
        require(_testPriceSource());
        _rebalanceDebtInternal();
    }

    function claimHarvest() internal virtual;

    /// called by keeper to harvest rewards and either repay debt
    function _harvestInternal() internal returns (uint256 _wantHarvested) {
        uint256 wantBefore = balanceOfWant();
        /// harvest from farm & wantd on amt borrowed vs LP value either -> repay some debt or add to collateral
        claimHarvest();
        comptroller.claimComp(address(this));
        _sellHarvestWant();
        _sellCompWant();
        _wantHarvested = balanceOfWant().sub(wantBefore);
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
        return
            cTokenLend.totalCollateralTokens().add(_amount) <
            cTokenLend.collateralCap();
    }

    function _rebalanceCollateralInternal() internal {

        
        uint256 collatRatio = calcCollateral();
        uint256 shortPos = balanceDebt();
        uint256 lendPos = balanceLend();

        if (collatRatio > collatTarget) {
            uint256 adjAmount =
                (shortPos.sub(lendPos.mul(collatTarget).div(BASIS_PRECISION)))
                    .mul(BASIS_PRECISION)
                    .div(BASIS_PRECISION.add(collatTarget));
            /// remove some LP use 50% of withdrawn LP to repay debt and half to add to collateral
            _withdrawLpRebalanceCollateral(adjAmount.mul(2));
            emit CollatRebalance(collatRatio, adjAmount);
        } else if (collatRatio < collatTarget) {
            uint256 adjAmount =
                ((lendPos.mul(collatTarget).div(BASIS_PRECISION)).sub(shortPos))
                    .mul(BASIS_PRECISION)
                    .div(BASIS_PRECISION.add(collatTarget));
            uint256 borrowAmt = _borrowWantEq(adjAmount);
            _redeemWant(adjAmount);
            _addToLP(borrowAmt);
            _depositAllLpInFarm();
            emit CollatRebalance(collatRatio, adjAmount);
        }
    }

    // deploy assets according to vault strategy
    function _deploy(uint256 _amount) internal {
        if (_amount < minDeploy || collateralCapReached(_amount)) {
            return;
        }

        uint256 oPrice = oracle.getPrice();
        uint256 lpPrice = getWantShortLpPrice();
        uint256 borrow =
            collatTarget.mul(_amount).mul(1e18).div(
                BASIS_PRECISION.mul(
                    (collatTarget.mul(lpPrice).div(BASIS_PRECISION).add(oPrice))
                )
            );
        uint256 debtAllocation = borrow.mul(lpPrice).div(1e18);
        uint256 lendNeeded = _amount.sub(debtAllocation);

        _lendWant(lendNeeded);
        _borrow(borrow);
        _addToLP(borrow);
        _depositAllLpInFarm();
    }

    // hh -> this functions should return a price similar to the oracle one. 
    // otherwise it means that the "equivalent" tokens are not correctly pegged
    function getFarmingLpPrice() public view returns (uint256) {
        (uint256 wantEquivalentInLp, uint256 shortEquivalentInLp) = _getFarmingLpReserves();
        return wantEquivalentInLp.mul(1e18).div(shortEquivalentInLp);
    }

    function getWantShortLpPrice() public view returns (uint256) {
        (uint256 wantInLp, uint256 shortInLp) = _getReservesGeneric(wantShortLP, address(want));
        return wantInLp.mul(1e18).div(shortInLp);
    }

    function getWantEquivalentPrice() public view returns (uint256) {
        (uint256 wantInLp, uint256 wantEquivalentInLp) = _getReservesGeneric(wantWantEquivalentLP, address(want));
        return wantInLp.mul(1e18).div(wantEquivalentInLp);
    }

    function getShortEquivalentPrice() public view returns (uint256) {
        (uint256 shortInLp, uint256 shortEquivalentInLp) = _getReservesGeneric(shortShortEquivalentLP, address(short));
        return shortInLp.mul(1e18).div(shortEquivalentInLp);
    }

    /**
     * @notice
     *  Reverts if the difference in the price sources are >  priceSourceDiff
     *  Hedgehog -> also check that farmingLpPrice is in line with the oracle price,
     *  And also that want<->wantEq and short<->shortEq is around 1
     */
    function _testPriceSource() internal view returns (bool) {
        if (doPriceCheck) {
            uint256 oPrice = oracle.getPrice();
            uint256 lpPrice = getWantShortLpPrice();
            uint256 priceSourceRatio = oPrice.mul(BASIS_PRECISION).div(lpPrice);
            if (priceSourceRatio < BASIS_PRECISION.sub(priceSourceDiff) ||
                priceSourceRatio > BASIS_PRECISION.add(priceSourceDiff))
                return false;
            //Check that want<->wantEq and short<->shortEq is around 1
            uint256 wantWantEqPrice = getWantEquivalentPrice() * BASIS_PRECISION / 1e18;
            if (wantWantEqPrice < BASIS_PRECISION.sub(priceSourceDiff) ||
                wantWantEqPrice > BASIS_PRECISION.add(priceSourceDiff))
                return false;
            uint256 shortShortEqPrice = getShortEquivalentPrice()  * BASIS_PRECISION / 1e18;
            if (shortShortEqPrice < BASIS_PRECISION.sub(priceSourceDiff) ||
                shortShortEqPrice > BASIS_PRECISION.add(priceSourceDiff))
                return false;

            //Check that farmingLpPrice is around oPrice
            uint256 fPrice = getFarmingLpPrice();
            priceSourceRatio = oPrice.mul(BASIS_PRECISION).div(fPrice);
            
            if (priceSourceRatio < BASIS_PRECISION.sub(priceSourceDiff) ||
                priceSourceRatio > BASIS_PRECISION.add(priceSourceDiff))
                return false;
        }
        return true;
    }

    /**
     * @notice
     *  Assumes all balance is in Lend outside of a small amount of debt and short. Deploys
     *  capital maintaining the collatRatioTarget
     *
     * @dev
     *  Some crafty maths here:
     *  B: borrow amount in short (Not total debt!)
     *  L: Lend in want
     *  Cr: Collateral Target
     *  Po: Oracle price (short * Po = want)
     *  Plp: LP Price
     *  Di: Initial Debt in short
     *  Si: Initial short balance
     *
     *  We want:
     *  Cr = BPo / L
     *  T = L + Plp(B + 2Si - Di)
     *
     *  Solving this for L finds:
     *  B = (TCr - Cr*Plp(2Si-Di)) / (Po + Cr*Plp)
     */
    function _calcDeployment(uint256 _amount)
        internal 
        view
        returns (uint256 _lendNeeded, uint256 _borrow)
    {
        uint256 oPrice = oracle.getPrice();
        uint256 lpPrice = getWantShortLpPrice();
        uint256 Si2 = balanceShort().mul(2);
        uint256 Di = balanceDebtInShort();
        uint256 CrPlp = collatTarget.mul(lpPrice);
        uint256 numerator;

        // NOTE: may throw if _amount * CrPlp > 1e70
        if (Di > Si2) {
            numerator = (
                collatTarget.mul(_amount).mul(1e18).add(CrPlp.mul(Di.sub(Si2)))
            )
                .sub(oPrice.mul(BASIS_PRECISION).mul(Di));
        } else {
            numerator = (
                collatTarget.mul(_amount).mul(1e18).sub(CrPlp.mul(Si2.sub(Di)))
            )
                .sub(oPrice.mul(BASIS_PRECISION).mul(Di));
        }

        _borrow = numerator.div(
            BASIS_PRECISION.mul(oPrice.add(CrPlp.div(BASIS_PRECISION)))
        );
        _lendNeeded = _amount.sub(
            (_borrow.add(Si2).sub(Di)).mul(lpPrice).div(1e18)
        );
    }

    function _deployFromLend(uint256 _amount) internal {
        (uint256 _lendNeeded, uint256 _borrowAmt) = _calcDeployment(_amount);
        _redeemWant(balanceLend().sub(_lendNeeded));
        _borrow(_borrowAmt);
        _addToLP(balanceShort());
        _depositAllLpInFarm();
    }


    function _rebalanceDebtInternal() internal {
        uint256 swapAmountWant;
        uint256 slippage;
        uint256 debtRatio = calcDebtRatio();

        // Liquidate all the lend, leaving some in debt or as short
        liquidateAllToLend();

        uint256 debtInShort = balanceDebtInShort();
        uint256 balShort = balanceShort();

        if (debtInShort > balShort) {
            uint256 debt = convertShortToWantLP(debtInShort);
            // If there's excess debt, we swap some want to repay a portion of the debt
            swapAmountWant = debt.mul(rebalancePercent).div(BASIS_PRECISION);
            _redeemWant(swapAmountWant);
            slippage = _swapExactWantShort(swapAmountWant);
            _repayDebt();
        } else {
            // If there's excess short, we swap some to want which will be used
            // to create lp in _deployFromLend()
            (swapAmountWant, slippage) = _swapExactShortWant(
                balanceShort().mul(rebalancePercent).div(BASIS_PRECISION)
            );
        }

        _deployFromLend(estimatedTotalAssets());
        emit DebtRebalance(debtRatio, swapAmountWant, slippage);
    }

    /**
     * Withdraws and removes `_deployedPercent` percentage if LP from farming and pool respectively
     *
     * @param _deployedPercent percentage multiplied by BASIS_PRECISION of LP to remove.
     */
    function _removeLpPercent(uint256 _deployedPercent) internal {
        uint256 lpPooled = countLpPooled();
        uint256 lpUnpooled = farmingLP.balanceOf(address(this));
        uint256 lpCount = lpUnpooled.add(lpPooled);
        uint256 lpReq = lpCount.mul(_deployedPercent).div(BASIS_PRECISION);
        uint256 lpWithdraw;
        if (lpReq - lpUnpooled < lpPooled) {
            lpWithdraw = lpReq.sub(lpUnpooled);
        } else {
            lpWithdraw = lpPooled;
        }

        // Finnally withdraw the LP from farms and remove from pool
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
        // Called by withdraw -> use test price source
        require(_testPriceSource());
        uint256 totalAssets = estimatedTotalAssets();

        // if estimatedTotalAssets is less than params.debtRatio it means there's
        // been a loss (ignores pending harvests). This type of loss is calculated
        // proportionally
        // This stops a run-on-the-bank if there's IL between harvests.
        uint256 newAmount = _amountNeeded;
        uint256 totalDebt = _getTotalDebt();
        if (totalDebt > totalAssets) {
            uint256 ratio = totalAssets.mul(STD_PRECISION).div(totalDebt);
            newAmount = _amountNeeded.mul(ratio).div(STD_PRECISION);
            _loss = _amountNeeded.sub(newAmount);
        }

        // Liquidate the amount needed
        (, uint256 _slippage) = _withdraw(newAmount);
        _loss = _loss.add(_slippage);

        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`
        _liquidatedAmount = balanceOfWant();
        if (_liquidatedAmount.add(_loss) > _amountNeeded) {
            _liquidatedAmount = _amountNeeded.sub(_loss);
        } else {
            _loss = _amountNeeded.sub(_liquidatedAmount);
        }
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
        require(_testPriceSource());
        uint256 balanceWant = balanceOfWant();
        if (_amountNeeded <= balanceWant) {
            return (_amountNeeded, 0);
        }

        uint256 balanceDeployed = balanceDeployed();

        // stratPercent: Percentage of the deployed capital we want to liquidate.
        uint256 stratPercent =
            _amountNeeded.sub(balanceWant).mul(BASIS_PRECISION).div(
                balanceDeployed
            );

        if (stratPercent > 9500) {
            // If this happened, we just undeploy the lot
            // and it'll be redeployed during the next harvest.
            (, _loss) = liquidateAllPositionsInternal();
            _liquidatedAmount = balanceOfWant().sub(balanceWant);
        } else {
            // liquidate all to lend
            liquidateAllToLend();

            // Only rebalance if more than 5% is being liquidated
            // to save on gas
            uint256 slippage = 0;
            if (stratPercent > 500) {
                // swap to ensure the debt ratio isn't negatively affected
                uint256 shortInShort = balanceShort();
                uint256 debtInShort = balanceDebtInShort();
                if (debtInShort > shortInShort) {
                    uint256 debt = convertShortToWantLP(debtInShort);
                    uint256 swapAmountWant =
                        debt.mul(stratPercent).div(BASIS_PRECISION);
                    _redeemWant(swapAmountWant);
                    slippage = _swapExactWantShort(swapAmountWant);
                    _repayDebt();
                } else {
                    (, slippage) = _swapExactShortWant(
                        balanceShort().mul(stratPercent).div(BASIS_PRECISION)
                    );
                }
            }

            // Redeploy the strat
            _deployFromLend(balanceDeployed.sub(_amountNeeded).add(slippage));
            _liquidatedAmount = balanceOfWant().sub(balanceWant);
            _loss = slippage;
        }
    }

    function enterMarket() internal {
        address[] memory cTokens = new address[](1);
        cTokens[0] = address(cTokenLend);
        comptroller.enterMarkets(cTokens);
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
        return balanceOfWant().add(balanceDeployed());
    }

    // calculate total value of vault assets
    function balanceDeployed() public view returns (uint256) {
        return
            balanceLend().add(balanceLp()).add(balanceShortWantEq()).sub(
                balanceDebt()
            );
    }

    // debt ratio - used to trigger rebalancing of debt
    function calcDebtRatio() public view returns (uint256) {
        return (balanceDebt().mul(BASIS_PRECISION).mul(2).div(balanceLp()));
    }

    // calculate debt / collateral - used to trigger rebalancing of debt & collateral
    function calcCollateral() public view returns (uint256) {
        return balanceDebtOracle().mul(BASIS_PRECISION).div(balanceLend());
    }

    function _getReservesGeneric(IUniswapV2Pair lp, address _firstToken) 
        internal
        view
        returns (uint256 _firstTokenInLp, uint256 _secondTokenInLp) 
    {
        (uint112 reserves0, uint112 reserves1, ) = lp.getReserves();
        if (farmingLP.token0() == address(_firstToken)) {
            _firstTokenInLp = uint256(reserves0);
            _secondTokenInLp = uint256(reserves1);
        } else {
            _firstTokenInLp = uint256(reserves1);
            _secondTokenInLp = uint256(reserves0);
        }
    }
    function _getFarmingLpReserves()
        internal
        view
        returns (uint256 _wantEquivalentInLp, uint256 _shortEquivalentInLp)
    {
        (uint112 reserves0, uint112 reserves1, ) = farmingLP.getReserves();
        if (farmingLP.token0() == address(wantEquivalent)) {
            _wantEquivalentInLp = uint256(reserves0);
            _shortEquivalentInLp = uint256(reserves1);
        } else {
            _wantEquivalentInLp = uint256(reserves1);
            _shortEquivalentInLp = uint256(reserves0);
        }
    }
    function convertShortToWantLP(uint256 _amountShort)
        internal
        view
        returns (uint256)
    {
        (uint256 wantInLp, uint256 shortInLp) = _getReservesGeneric(wantShortLP, address(want));
        return (_amountShort.mul(wantInLp).div(shortInLp));
    }

    function convertShortToWantOracle(uint256 _amountShort)
        internal
        view
        returns (uint256)
    {
        return _amountShort.mul(oracle.getPrice()).div(1e18);
    }

    function convertWantToShortLP(uint256 _amountWant)
        internal
        view
        returns (uint256)
    {
        (uint256 wantInLp, uint256 shortInLp) = _getFarmingLpReserves();
        return _amountWant.mul(shortInLp).div(wantInLp);
    }

    function _convertWantToWantEquivalent(uint256 _amountWant)
        internal
        view
        returns (uint256)
    {
        (uint256 wantInLp, uint256 wantEquivalentInLp) = _getReservesGeneric(wantWantEquivalentLP, address(want));
        return _amountWant.mul(wantEquivalentInLp).div(wantInLp);
    }

    function _convertWantEquivalentToWant(uint256 _amountWantEquivalent)
        internal
        view
        returns (uint256)
    {
        (uint256 wantEquivalentInLp, uint256 wantInLp) = _getReservesGeneric(wantWantEquivalentLP, address(wantEquivalent));
        return _amountWantEquivalent.mul(wantInLp).div(wantEquivalentInLp);
    }

    function _convertShortToShortEquivalent(uint256 _amountShort)
        internal
        view
        returns (uint256)
    {
        (uint256 shortInLp, uint256 shortEquivalentInLp) = _getReservesGeneric(shortShortEquivalentLP, address(short));
        return _amountShort.mul(shortEquivalentInLp).div(shortInLp);
    }

    function _convertShortEquivalentToShort(uint256 _amountShortEquivalent)
        internal
        view
        returns (uint256)
    {
        (uint256 shortEquivalentInLp, uint256 shortInLp) = _getReservesGeneric(shortShortEquivalentLP, address(shortEquivalent));
        return _amountShortEquivalent.mul(shortInLp).div(shortEquivalentInLp);
    }

    function balanceLpInShort() public view returns (uint256) {
        return countLpPooled().add(farmingLP.balanceOf(address(this)));        
    }

    /// get value of all LP in want currency
    function balanceLp() public view returns (uint256) {
        (uint256 wantInLp, ) = _getFarmingLpReserves();
        return
            balanceLpInShort().mul(wantInLp).mul(2).div(
                farmingLP.totalSupply()
            );
    }

    // value of borrowed tokens in value of want tokens
    function balanceDebtInShort() public view returns (uint256) {
        return cTokenBorrow.borrowBalanceStored(address(this));
    }

    // value of borrowed tokens in value of want tokens
    // Uses current exchange price, not stored
    function balanceDebtInShortCurrent() internal returns (uint256) {
        return cTokenBorrow.borrowBalanceCurrent(address(this));
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
        uint256 rewardsPending =
            _farmPendingRewards(farmPid, address(this)).add(
                farmToken.balanceOf(address(this))
            );
        (uint256 shortInLp, uint256 harvestInLp) = _getReservesGeneric(farmTokenLP, address(short));
        uint256 rewardsInShort = rewardsPending.mul(shortInLp).div(harvestInLp);

        return convertShortToWantOracle(rewardsInShort.mul(BASIS_PRECISION)).div(BASIS_PRECISION);
    }
    // HHTODO Check all these balances
    // reserves
    function balanceOfWant() public view returns (uint256) {
        return (want.balanceOf(address(this)));
    }

    function balanceShort() public view returns (uint256) {
        return (short.balanceOf(address(this)));
    }

    function balanceWantEquivalent() public view returns (uint256) {
        return (wantEquivalent.balanceOf(address(this)));
    }

    function balanceShortEquivalent() public view returns (uint256) {
        return (shortEquivalent.balanceOf(address(this)));
    }
    function balanceShortWantEq() public view returns (uint256) {
        return convertShortToWantOracle(balanceShort());
    }

    function balanceLend() public view returns (uint256) {
        return (
            cTokenLend
                .balanceOf(address(this))
                .mul(cTokenLend.exchangeRateStored())
                .div(1e18)
        );
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

    // borrow tokens worth _amount of want tokens
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

    function _redeemWant(uint256 _redeem_amount) internal {
        cTokenLend.redeemUnderlying(_redeem_amount);
    }
    // HHTODO remove? not used anywhere, and it is identical to _withdrawLpRebalanceCollateral
    // withdraws some LP worth _amount, converts all withdrawn LP to short token to repay debt
    function _withdrawLpRebalance(uint256 _amount)
        internal
        returns (uint256 swapAmountWant, uint256 slippageWant)
    {
        uint256 lpUnpooled = farmingLP.balanceOf(address(this));
        uint256 lpPooled = countLpPooled();
        uint256 lpCount = lpUnpooled.add(lpPooled);
        uint256 lpReq = _amount.mul(lpCount).div(balanceLp());
        uint256 lpWithdraw;
        if (lpReq - lpUnpooled < lpPooled) {
            lpWithdraw = lpReq - lpUnpooled;
        } else {
            lpWithdraw = lpPooled;
        }
        _withdrawAmountFromFarm(lpWithdraw);
        _removeAllLp();
        swapAmountWant = Math.min(
            _amount.div(2),
            want.balanceOf(address(this))
        );
        slippageWant = _swapExactWantShort(swapAmountWant);

        _repayDebt();
    }

    //  withdraws some LP worth _amount, uses withdrawn LP to add to collateral & repay debt
    function _withdrawLpRebalanceCollateral(uint256 _amount) internal {
        uint256 lpUnpooled = farmingLP.balanceOf(address(this));
        uint256 lpPooled = countLpPooled();
        uint256 lpCount = lpUnpooled.add(lpPooled);
        uint256 lpReq = _amount.mul(lpCount).div(balanceLp());
        uint256 lpWithdraw;
        if (lpReq - lpUnpooled < lpPooled) {
            lpWithdraw = lpReq - lpUnpooled;
        } else {
            lpWithdraw = lpPooled;
        }
        _withdrawAmountFromFarm(lpWithdraw);
        _removeAllLp();
        // HHTODO improve using Math.min()
        uint256 wantBal = balanceOfWant();
        if (_amount.div(2) <= wantBal) {
            _lendWant(_amount.div(2));
        } else {
            _lendWant(wantBal);
        }
        _repayDebt();
    }

    function _addToLP(uint256 _amountShort) internal {
        uint256 _amountWant = Math.min(convertShortToWantLP(_amountShort), balanceOfWant());

        //Swap necessary short, want to equivalents
        uint256 _amountShortToSwap = _amountShort - balanceShortEquivalent();
        if(_amountShortToSwap > 0 ) {
            _swapShortToShortEquivalent(_amountShortToSwap);
        }
        uint256 _amountWantToSwap = _amountWant - balanceWantEquivalent();
        if(_amountWantToSwap > 0 ) {
            _swapWantToWantEquivalent(_amountShortToSwap);
        }
        uint256 _amountWantEquivalent = balanceWantEquivalent();
        uint256 _amountShortEquivalent = balanceShortEquivalent();
        
        farmRouter.addLiquidity(
            address(short),
            address(want),
            _amountShortEquivalent,
            _amountWantEquivalent,
            _amountShortEquivalent.mul(slippageAdj).div(BASIS_PRECISION),
            _amountWantEquivalent.mul(slippageAdj).div(BASIS_PRECISION),
            address(this),
            now
        );
    }

    function _cleanUpEquivalent() internal {
        _swapWantEquivalentToWant(balanceWantEquivalent());
        _swapShortEquivalentToShort(balanceShortEquivalent());
    }

    function _depositAllLpInFarm() internal virtual {
        uint256 lpBalance = farmingLP.balanceOf(address(this)); /// get number of LP tokens
        farm.deposit(farmPid, lpBalance); /// deposit LP tokens to farm
    }

    function _withdrawFarm(uint256 _amount) internal virtual {
        farm.withdraw(farmPid, _amount);
    }

    function _withdrawAmountFromFarm(uint256 _amount) internal {
        require(_amount <= countLpPooled());
        _withdrawFarm(_amount);
    }

    function _withdrawAllPooled() internal {
        uint256 lpPooled = countLpPooled();
        _withdrawFarm(lpPooled);
    }

    // all LP currently not in Farm is removed.
    function _removeAllLp() internal {
        uint256 _amount = farmingLP.balanceOf(address(this));
        (uint256 wantLP, uint256 shortLP) = _getFarmingLpReserves();
        uint256 lpIssued = farmingLP.totalSupply();

        uint256 amountAMin =
            _amount.mul(shortLP).mul(slippageAdj).div(BASIS_PRECISION).div(
                lpIssued
            );
        uint256 amountBMin =
            _amount.mul(wantLP).mul(slippageAdj).div(BASIS_PRECISION).div(
                lpIssued
            );
        router.removeLiquidity(
            address(short),
            address(want),
            _amount,
            amountAMin,
            amountBMin,
            address(this),
            now
        );
        _cleanUpEquivalent();
    }

    function _sellHarvestWant() internal virtual {
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
    function _sellCompWant() internal virtual {
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
            amountOutMin.mul(slippageAdj).div(BASIS_PRECISION),
            getTokenOutPath(address(want), address(short)), // _pathWantToShort(),
            address(this),
            now
        );
        slippageWant = convertShortToWantLP(
            amountOutMin.sub(amounts[amounts.length - 1])
        );
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
                _amountWant.mul(slippageAdj).div(BASIS_PRECISION),
                getTokenOutPath(address(short), address(want)),
                address(this),
                now
            );
        _slippageWant = _amountWant.sub(amounts[amounts.length - 1]);
    }


    //TODO add router and LP for this
    function _swapWantShortExact(uint256 _amountOut)
        internal
        returns (uint256 _slippageWant)
    {
        uint256 amountInWant = convertShortToWantLP(_amountOut);
        uint256 amountInMax =
            (amountInWant.mul(BASIS_PRECISION).div(slippageAdj)).add(10); // add 1 to make up for rounding down
        uint256[] memory amounts =
            router.swapTokensForExactTokens(
                _amountOut,
                amountInMax,
                getTokenOutPath(address(want), address(short)),
                address(this),
                now
            );
        _slippageWant = amounts[0].sub(amountInWant);
    }

    function _swapWantToWantEquivalent(uint256 _amount) 
        internal
        returns (uint256 _slippage) 
    {
        uint256 _amountInTheory =_convertWantToWantEquivalent(_amount);
        address[] memory _path = new address[](2);
        _path[0] = address(want);
        _path[1] = address(wantEquivalent);
        uint256[] memory amounts =
            router.swapExactTokensForTokens(
                _amount,
                _amount.mul(slippageAdj).div(BASIS_PRECISION),
                _path,
                address(this),
                now
            );
        _slippage = _amountInTheory.sub(amounts[amounts.length - 1]);
    
    }

    function _swapWantEquivalentToWant(uint256 _amount) 
        internal
        returns (uint256 _slippage) 
    {
        uint256 _amountInTheory = _convertWantEquivalentToWant(_amount);
        address[] memory _path = new address[](2);
        _path[0] = address(wantEquivalent);
        _path[1] = address(want);
        uint256[] memory amounts =
            router.swapExactTokensForTokens(
                _amount,
                _amount.mul(slippageAdj).div(BASIS_PRECISION),
                _path,
                address(this),
                now
            );
        _slippage = _amountInTheory.sub(amounts[amounts.length - 1]);
    
    }

    function _swapShortToShortEquivalent(uint256 _amount) 
        internal
        returns (uint256 _slippage) 
    {
        uint256 _amountInTheory = _convertShortToShortEquivalent(_amount);
        address[] memory _path = new address[](2);
        _path[0] = address(short);
        _path[1] = address(shortEquivalent);
        uint256[] memory amounts =
            router.swapExactTokensForTokens(
                _amount,
                _amount.mul(slippageAdj).div(BASIS_PRECISION),
                _path,
                address(this),
                now
            );
        _slippage = _amountInTheory.sub(amounts[amounts.length - 1]);
    
    }

    function _swapShortEquivalentToShort(uint256 _amount) 
        internal
        returns (uint256 _slippage) 
    {
        uint256 _amountInTheory = _convertShortEquivalentToShort(_amount);
        address[] memory _path = new address[](2);
        _path[0] = address(shortEquivalent);
        _path[1] = address(short);
        
        uint256[] memory amounts =
            router.swapExactTokensForTokens(
                _amount,
                _amount.mul(slippageAdj).div(BASIS_PRECISION),
                _path,
                address(this),
                now
            );
        _slippage = _amountInTheory.sub(amounts[amounts.length - 1]);
    
    }

    /**
     * @notice
     *  Intentionally not implmenting this. The justification being:
     *   1. It doesn't actually add any additional security because gov
     *      has the powers to do the same thing with addStrategy already
     *   2. Being able to sweep tokens from a strategy could be helpful
     *      incase of an unexpected catastropic failure.
     */
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}
}










// TODO check price only once in a transaction?
// TODO enable emergency mode -> disable price check

