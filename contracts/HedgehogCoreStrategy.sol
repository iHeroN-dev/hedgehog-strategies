// SPDX-License-Identifier: MIT

pragma solidity ^0.8.1;

import "./BaseStrategy.sol";
import "./HedgehogCoreStrategyConfig.sol";

abstract contract HedgehogCoreStrategy is BaseStrategy {

    event DebtRebalance(
        uint256 debtRatio,
        uint256 swapAmount,
        uint256 slippage
    );
    
    event CollateralRebalance(
        uint256 collateralRatio,
        uint256 adjAmount
    );

    uint256 public stratLendAllocation;
    uint256 public stratDebtAllocation;
    uint256 public debtUpper = 10200;
    uint256 public debtLower = 9800;
    uint256 public rebalancePercent = 10000; // 100% (how far does rebalance of debt move towards 100% from threshold)

    // protocol limits & upper, target and lower thresholds for ratio of debt to collateral
    uint256 public collateralLimit = 7500; 
    uint256 public collateralUpper = 6500; //65%
    uint256 public collateralTarget = 5000; //50%
    uint256 public collateralLower = 3500; //35%

    // ERC20 Tokens;
    IERC20 tokenToBorrow;
    IERC20 stablecoinForLP;
    IERC20 secondTokenForLP;
    IERC20 farmToken;
    IERC20 farmLP;

    //LP pair to farm with
    IUniswapV2Pair farmingLP; 

    // Contract Interfaces
    //...

    FarmWrapper targetFarm;
    uint256 farmPid;
    address weth;

    constructor(address _vault, HedgehogCoreStrategyConfig memory _config)
        public
        BaseStrategy(_vault) {
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


}


