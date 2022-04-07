// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./HedgehogCoreStrategy.sol";
contract MAITOMBTshareStrategy is HedgehogCoreStrategy {
    constructor(address _vault)
        public
        HedgehogCoreStrategy(
            _vault,
            HedgehogCoreStrategyConfig(
                0xfB98B335551a418cD0737375a2ea0ded62Ea213b, // want
                0x6c021Ae822BEa943b2E66552bDe1D2696a53fbB7, // short
                0x45f4682B560d4e3B8FF1F1b3A38FDBe775C7177b, // wantShortLP
                0x4cdF39285D7Ca8eB3f090fDA0C069ba5F4145B37, // farmToken -> Tshare
                0x4733bc45eF91cF7CcEcaeeDb794727075fB209F2, // farmTokenLp
                0xcc0a87f7e7c693042a9cc703661f5060c80acb43, // farmMasterChef
                2, // farmPid -> 2 for MAI/TOMB
                0x6D0176C5ea1e44b08D3dd001b0784cE42F47a3A7, // tombswap router
                0x0, // cTokenLend
                0x0, // cTokenBorrow
                0x0, // compToken
                0x0, // compTokenLP
                0x0, // comptroller
                0xF491e7B69E4244ad4002BC14e878a34207E38c29 // router
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