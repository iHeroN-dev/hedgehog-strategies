// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2; 

import "./Interfaces.sol";
interface TombFinanceFarm is IFarmMasterChef{
    function pendingShare(uint256 _pid, address _user)
        external
        view
        returns (uint256);
}