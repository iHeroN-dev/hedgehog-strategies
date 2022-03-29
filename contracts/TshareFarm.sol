interface TshareFarm {
    function pendingShare(uint256 _pid, address _user) external view returns (uint256);

    function withdraw(uint256 _pid, uint256 _amount) external;

    function deposit(uint256 _pid, uint256 _amount) external;

}