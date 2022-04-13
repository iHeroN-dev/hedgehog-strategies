// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./HedgehogCoreStrategy.sol";
import "./TombFinanceFarm.sol";
contract MAITOMBTshareStrategy is HedgehogCoreStrategy {
    constructor(address _vault)
        public
        HedgehogCoreStrategy(
            _vault,
            HedgehogCoreStrategyConfig(
                0xfB98B335551a418cD0737375a2ea0ded62Ea213b, // want
                0x6c021Ae822BEa943b2E66552bDe1D2696a53fbB7, // short
                0xfB98B335551a418cD0737375a2ea0ded62Ea213b, // wantEquivalent -> MAI
                0x6c021Ae822BEa943b2E66552bDe1D2696a53fbB7, //shortEquivalent -> tomb
                0x45f4682B560d4e3B8FF1F1b3A38FDBe775C7177b, // farmingLP -> MAI/TOMB
                0x4cdF39285D7Ca8eB3f090fDA0C069ba5F4145B37, // farmToken -> Tshare
                0x4733bc45eF91cF7CcEcaeeDb794727075fB209F2, // farmTokenLp
                0xcc0a87F7e7c693042a9Cc703661F5060c80ACb43, // farmMasterChef
                2, // farmPid -> 2 for MAI/TOMB
                0x6D0176C5ea1e44b08D3dd001b0784cE42F47a3A7, // tombswap router
                0xE45Ac34E528907d0A0239ab5Db507688070B20bf, // cTokenLend
                0x5AA53f03197E08C4851CAD8C92c7922DA5857E5d, // cTokenBorrow
                0xe0654C8e6fd4D733349ac7E09f6f23DA256bF475, // compToken
                0x30872e4fc4edbFD7a352bFC2463eb4fAe9C09086, // compTokenLP
                0x260E596DAbE3AFc463e75B6CC05d8c46aCAcFB09, // comptroller
                0xF491e7B69E4244ad4002BC14e878a34207E38c29, // router
                1e4 //MinDeploy
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
        return TombFinanceFarm(address(farm)).pendingShare(_pid, _user);
    }

    function _depositAllLpInFarm() internal override {
        uint256 lpBalance = farmingLP.balanceOf(address(this));
        TombFinanceFarm(address(farm)).deposit(farmPid, lpBalance);
    }

    function _withdrawFarm(uint256 _amount) internal override {
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

}