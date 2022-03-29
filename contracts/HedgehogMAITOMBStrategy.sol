// SPDX-License-Identifier: MIT

pragma solidity ^0.8.1;


import "./BaseStrategy.sol";
import "./HedgehogCoreStrategyConfig.sol";
import "./HedgehogCoreStrategy.sol";
import "./TshareFarm.sol";

contract HedgehogMAITOMBStrategy is HedgehogCoreStrategy {
    constructor(address _vault) public
        HedgehogCoreStrategy(
            _vault,
            HedgehogCoreStrategyConfig(
               //TODO
            )
        )
    {
        // create a default oracle and set it //TODO
        oracle = new ScreamPriceOracle(
            address(comptroller),
            address(cTokenLend),
            address(cTokenBorrow)
        );
    }

    function _getPendingFarmRewards()
        internal
        view
        override
        returns (uint256)
    {
        return LqdrFarm(address(farm)).pendingLqdr(_pid, _user);
    }

    function _depoistLp() internal override {
        uint256 lpBalance = wantShortLP.balanceOf(address(this));
        LqdrFarm(address(farm)).deposit(farmPid, lpBalance, address(this));
    }

    function _withdrawFarm(uint256 _amount) internal override {
        LqdrFarm(address(farm)).withdraw(farmPid, _amount, address(this));
    }

    function claimHarvest() internal override {
        LqdrFarm(address(farm)).harvest(farmPid, address(this));
    }

    /**
     * Checks if collateral cap is reached or if deploying `_amount` will make it reach the cap
     * returns true if the cap is reached
     */
    function collateralCapReached(uint256 _amount)
        public
        view
        override
        returns (bool _capReached)
    {
        uint256 cap =
            ComptrollerV5Storage(address(comptroller)).supplyCaps(
                address(cTokenLend)
            );

        // If the cap is zero, there is no cap.
        if (cap == 0) return false;

        uint256 totalCash = cTokenLend.getCash();
        uint256 totalBorrows = cTokenLend.totalBorrows();
        uint256 totalReserves = cTokenLend.totalReserves();
        uint256 totalCollateralised =
            totalCash.add(totalBorrows).sub(totalReserves);
        return totalCollateralised.add(_amount) > cap;
    }

    function balanceLendCollateral() public view override returns (uint256) {
        return balanceLend();
    }
}