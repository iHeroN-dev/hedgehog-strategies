// SPDX-License-Identifier: MIT

pragma solidity 0.8.13;

contract MAITOMBTshareStrategy is HedgehogCoreStrategy {
    constructor(address _vault)
        public
        CoreStrategy(
            _vault,
            CoreStrategyConfig(
                0xfB98B335551a418cD0737375a2ea0ded62Ea213b, // want
                0x6c021Ae822BEa943b2E66552bDe1D2696a53fbB7, // short
                0x45f4682B560d4e3B8FF1F1b3A38FDBe775C7177b, // wantShortLP
                0x4cdF39285D7Ca8eB3f090fDA0C069ba5F4145B37, // farmToken -> Tshare
                , // farmTokenLp
                0xcc0a87f7e7c693042a9cc703661f5060c80acb43, // farmMasterChef
                2, // farmPid -> 2 for MAI/TOMB
                , // cTokenLend
                , // cTokenBorrow
                , // compToken
                , // compTokenLP
                , // comptroller
                 // router
            )
        )
    {
        // create a default oracle and set it
        oracle = new ScreamPriceOracle(
            address(comptroller),
            address(cTokenLend),
            address(cTokenBorrow)
        );
    }

    function _farmPendingRewards(uint256 _pid, address _user)
        internal
        view
        override
        returns (uint256)
    {
        return TombFinanceFarm(address(farm)).pendingTShare(_pid, _user);
    }

    function _depositAllLpInFarm() internal override {
        uint256 lpBalance = wantShortLP.balanceOf(address(this));
        TombFinanceFarm(address(farm)).deposit(farmPid, lpBalance);
    }

    function _withdrawAmountFromFarm(uint256 _amount) internal override {
        TombFinanceFarm(address(farm)).withdraw(farmPid, _amount);
    }

    function claimHarvest() internal override {
        _withdrawFarm(0); // Tomb does not have an harvest function, so we need to do a withdraw of 0 LP tokens
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