// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2; 
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

struct UserInfo {
    uint256 amount; // How many LP tokens the user has provided.
    uint256 rewardDebt; // Reward debt.
}

struct CoreStrategyConfig {
    // A portion of want token is depoisited into a lending platform to be used as
    // collateral. Short token is borrowed and compined with the remaining want token
    // and deposited into LP and farmed.
    address want;
    address short;
    /*****************************/
    /*             Farm           */
    /*****************************/
    // Liquidity pool address for base <-> short tokens
    address wantShortLP;
    // Address for farming reward token - eg Spirit/BOO
    address farmToken;
    // Liquidity pool address for farmToken <-> wFTM
    address farmTokenLP;
    // Farm address for reward farming
    address farmMasterChef;
    // farm PID for base <-> short LP farm
    uint256 farmPid;
    /*****************************/
    /*        Money Market       */
    /*****************************/
    // Base token cToken @ MM
    address cTokenLend;
    // Short token cToken @ MM
    address cTokenBorrow;
    // Lend/Borrow rewards
    address compToken;
    address compTokenLP;
    // address compLpAddress = 0x613BF4E46b4817015c01c6Bb31C7ae9edAadc26e;
    address comptroller;
    /*****************************/
    /*            AMM            */
    /*****************************/
    // Liquidity pool address for base <-> short tokens @ the AMM.
    // @note: the AMM router address does not need to be the same
    // AMM as the farm, in fact the most liquid AMM is prefered to
    // minimise slippage.
    address router;
    uint256 minDeploy;
}

// Part: ICTokenStorage

interface ICTokenStorage {
    /**
     * @dev Container for borrow balance information
     * @member principal Total balance (with accrued interest), after applying the most recent balance-changing action
     * @member interestIndex Global borrowIndex as of the most recent balance-changing action
     */
    struct BorrowSnapshot {
        uint256 principal;
        uint256 interestIndex;
    }
}

// Part: ICompPriceOracle

interface ICompPriceOracle {
    function isPriceOracle() external view returns (bool);

    /**
     * @notice Get the underlying price of a cToken asset
     * @param cToken The cToken to get the underlying price of
     * @return The underlying asset price mantissa (scaled by 1e18).
     *  Zero means the price is unavailable.
     */
    function getUnderlyingPrice(address cToken) external view returns (uint256);
}

// Part: IComptroller

interface IComptroller {
    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata cTokens)
        external
        returns (uint256[] memory);

    function exitMarket(address cToken) external returns (uint256);

    /*** Policy Hooks ***/

    function mintAllowed(
        address cToken,
        address minter,
        uint256 mintAmount
    ) external returns (uint256);

    function mintVerify(
        address cToken,
        address minter,
        uint256 mintAmount,
        uint256 mintTokens
    ) external;

    function redeemAllowed(
        address cToken,
        address redeemer,
        uint256 redeemTokens
    ) external returns (uint256);

    function redeemVerify(
        address cToken,
        address redeemer,
        uint256 redeemAmount,
        uint256 redeemTokens
    ) external;

    function borrowAllowed(
        address cToken,
        address borrower,
        uint256 borrowAmount
    ) external returns (uint256);

    function borrowVerify(
        address cToken,
        address borrower,
        uint256 borrowAmount
    ) external;

    function repayBorrowAllowed(
        address cToken,
        address payer,
        address borrower,
        uint256 repayAmount
    ) external returns (uint256);

    function repayBorrowVerify(
        address cToken,
        address payer,
        address borrower,
        uint256 repayAmount,
        uint256 borrowerIndex
    ) external;

    function liquidateBorrowAllowed(
        address cTokenBorrowed,
        address cTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount
    ) external returns (uint256);

    function liquidateBorrowVerify(
        address cTokenBorrowed,
        address cTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount,
        uint256 seizeTokens
    ) external;

    function seizeAllowed(
        address cTokenCollateral,
        address cTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external returns (uint256);

    function seizeVerify(
        address cTokenCollateral,
        address cTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external;

    function transferAllowed(
        address cToken,
        address src,
        address dst,
        uint256 transferTokens
    ) external returns (uint256);

    function transferVerify(
        address cToken,
        address src,
        address dst,
        uint256 transferTokens
    ) external;

    function claimComp(address holder) external;

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(
        address cTokenBorrowed,
        address cTokenCollateral,
        uint256 repayAmount
    ) external view returns (uint256, uint256);
}

// Part: IPriceOracle

interface IPriceOracle {
    function getPrice() external view returns (uint256);
}

// Part: IStrategyInsurance

interface IStrategyInsurance {
    function reportProfit(uint256 _totalDebt, uint256 _profit)
        external
        returns (uint256 _wantNeeded);

    function reportLoss(uint256 _totalDebt, uint256 _loss)
        external
        returns (uint256 _compensation);
}

// Part: IUniswapV2Pair

interface IUniswapV2Pair {
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
    event Transfer(address indexed from, address indexed to, uint256 value);

    function name() external pure returns (string memory);

    function symbol() external pure returns (string memory);

    function decimals() external pure returns (uint8);

    function totalSupply() external view returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function allowance(address owner, address spender)
        external
        view
        returns (uint256);

    function approve(address spender, uint256 value) external returns (bool);

    function transfer(address to, uint256 value) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function PERMIT_TYPEHASH() external pure returns (bytes32);

    function nonces(address owner) external view returns (uint256);

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address indexed to
    );
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint256);

    function factory() external view returns (address);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );

    function price0CumulativeLast() external view returns (uint256);

    function price1CumulativeLast() external view returns (uint256);

    function kLast() external view returns (uint256);

    function mint(address to) external returns (uint256 liquidity);

    function burn(address to)
        external
        returns (uint256 amount0, uint256 amount1);

    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    function skim(address to) external;

    function sync() external;

    function initialize(address, address) external;
}

// Part: IUniswapV2Router01

interface IUniswapV2Router01 {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        );

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountETH);

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityETHWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountToken, uint256 amountETH);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapETHForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) external pure returns (uint256 amountB);

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountOut);

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountIn);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    function getAmountsIn(uint256 amountOut, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

// Part: InterestRateModel

/**
 * @title Compound's InterestRateModel Interface
 * @author Compound
 */
interface InterestRateModel {
    /**
     * @dev Calculates the current borrow interest rate per block
     * @param cash The total amount of cash the market has
     * @param borrows The total amount of borrows the market has outstanding
     * @param reserves The total amnount of reserves the market has
     * @return The borrow rate per block (as a percentage, and scaled by 1e18)
     */
    function getBorrowRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) external view returns (uint256);

    /**
     * @dev Calculates the current supply interest rate per block
     * @param cash The total amount of cash the market has
     * @param borrows The total amount of borrows the market has outstanding
     * @param reserves The total amnount of reserves the market has
     * @param reserveFactorMantissa The current reserve factor the market has
     * @return The supply rate per block (as a percentage, and scaled by 1e18)
     */
    function getSupplyRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves,
        uint256 reserveFactorMantissa
    ) external view returns (uint256);
}

// Part: LqdrFarm

interface LqdrFarm {
    function pendingLqdr(uint256 _pid, address _user)
        external
        view
        returns (uint256);

    function harvest(uint256 _pid, address _to) external;

    function deposit(
        uint256 _pid,
        uint256 _wantAmt,
        address _sponsor
    ) external;

    function withdraw(
        uint256 _pid,
        uint256 _amount,
        address _to
    ) external;

    function userInfo(uint256 _pid, address user)
        external
        view
        returns (uint256, int256);
}


// Part: UnitrollerAdminStorage

interface UnitrollerAdminStorage {
    /**
     * @notice Administrator for this contract
     */
    // address external admin;
    function admin() external view returns (address);

    /**
     * @notice Pending administrator for this contract
     */
    // address external pendingAdmin;
    function pendingAdmin() external view returns (address);

    /**
     * @notice Active brains of Unitroller
     */
    // address external comptrollerImplementation;
    function comptrollerImplementation() external view returns (address);

    /**
     * @notice Pending brains of Unitroller
     */
    // address external pendingComptrollerImplementation;
    function pendingComptrollerImplementation() external view returns (address);
}

// Part: yearn/yearn-vaults@0.4.3/HealthCheck

interface HealthCheck {
    function check(
        uint256 profit,
        uint256 loss,
        uint256 debtPayment,
        uint256 debtOutstanding,
        uint256 totalDebt
    ) external view returns (bool);
}

// Part: ComptrollerV1Storage

interface ComptrollerV1Storage is UnitrollerAdminStorage {
    /**
     * @notice Oracle which gives the price of any given asset
     */
    // PriceOracle external oracle;
    function oracle() external view returns (address);

    /**
     * @notice Multiplier used to calculate the maximum repayAmount when liquidating a borrow
     */
    // uint external closeFactorMantissa;
    function closeFactorMantissa() external view returns (uint256);

    /**
     * @notice Multiplier representing the discount on collateral that a liquidator receives
     */
    // uint external liquidationIncentiveMantissa;
    function liquidationIncentiveMantissa() external view returns (uint256);

    /**
     * @notice Max number of assets a single account can participate in (borrow or use as collateral)
     */
    // uint external maxAssets;
    function maxAssets() external view returns (uint256);

    /**
     * @notice Per-account mapping of "assets you are in", capped by maxAssets
     */
    // mapping(address => CToken[]) external accountAssets;
    // function accountAssets(address) external view returns (CToken[]);
}

// Part: ICToken

interface ICToken is ICTokenStorage {
    /*** Market Events ***/

    /**
     * @dev Event emitted when interest is accrued
     */
    event AccrueInterest(
        uint256 cashPrior,
        uint256 interestAccumulated,
        uint256 borrowIndex,
        uint256 totalBorrows
    );

    /**
     * @dev Event emitted when tokens are minted
     */
    event Mint(address minter, uint256 mintAmount, uint256 mintTokens);

    /**
     * @dev Event emitted when tokens are redeemed
     */
    event Redeem(address redeemer, uint256 redeemAmount, uint256 redeemTokens);

    /**
     * @dev Event emitted when underlying is borrowed
     */
    event Borrow(
        address borrower,
        uint256 borrowAmount,
        uint256 accountBorrows,
        uint256 totalBorrows
    );

    /**
     * @dev Event emitted when a borrow is repaid
     */
    event RepayBorrow(
        address payer,
        address borrower,
        uint256 repayAmount,
        uint256 accountBorrows,
        uint256 totalBorrows
    );

    /**
     * @dev Event emitted when a borrow is liquidated
     */
    event LiquidateBorrow(
        address liquidator,
        address borrower,
        uint256 repayAmount,
        address cTokenCollateral,
        uint256 seizeTokens
    );

    /*** Admin Events ***/

    /**
     * @dev Event emitted when pendingAdmin is changed
     */
    event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);

    /**
     * @dev Event emitted when pendingAdmin is accepted, which means admin is updated
     */
    event NewAdmin(address oldAdmin, address newAdmin);

    /**
     * @dev Event emitted when comptroller is changed
     */
    event NewComptroller(
        IComptroller oldComptroller,
        IComptroller newComptroller
    );

    /**
     * @dev Event emitted when interestRateModel is changed
     */
    event NewMarketInterestRateModel(
        InterestRateModel oldInterestRateModel,
        InterestRateModel newInterestRateModel
    );

    /**
     * @dev Event emitted when the reserve factor is changed
     */
    event NewReserveFactor(
        uint256 oldReserveFactorMantissa,
        uint256 newReserveFactorMantissa
    );

    /**
     * @dev Event emitted when the reserves are added
     */
    event ReservesAdded(
        address benefactor,
        uint256 addAmount,
        uint256 newTotalReserves
    );

    /**
     * @dev Event emitted when the reserves are reduced
     */
    event ReservesReduced(
        address admin,
        uint256 reduceAmount,
        uint256 newTotalReserves
    );

    /**
     * @dev EIP20 Transfer event
     */
    event Transfer(address indexed from, address indexed to, uint256 amount);

    /**
     * @dev EIP20 Approval event
     */
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 amount
    );

    /**
     * @dev Failure event
     */
    event Failure(uint256 error, uint256 info, uint256 detail);

    /*** User Interface ***/
    function totalBorrows() external view returns (uint256);

    function totalReserves() external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function transfer(address dst, uint256 amount) external returns (bool);

    function transferFrom(
        address src,
        address dst,
        uint256 amount
    ) external returns (bool);

    function approve(address spender, uint256 amount) external returns (bool);

    function allowance(address owner, address spender)
        external
        view
        returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function balanceOfUnderlying(address owner) external returns (uint256);

    function getAccountSnapshot(address account)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        );

    function borrowRatePerBlock() external view returns (uint256);

    function supplyRatePerBlock() external view returns (uint256);

    function totalBorrowsCurrent() external returns (uint256);

    function borrowBalanceCurrent(address account) external returns (uint256);

    function borrowBalanceStored(address account)
        external
        view
        returns (uint256);

    function exchangeRateCurrent() external returns (uint256);

    function exchangeRateStored() external view returns (uint256);

    function getCash() external view returns (uint256);

    function accrueInterest() external returns (uint256);

    function seize(
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external returns (uint256);

    /*** CCap Interface ***/

    function totalCollateralTokens() external view returns (uint256);

    function accountCollateralTokens(address account)
        external
        view
        returns (uint256);

    function isCollateralTokenInit(address account)
        external
        view
        returns (bool);

    function collateralCap() external view returns (uint256);

    /*** Admin Functions ***/

    function _setPendingAdmin(address payable newPendingAdmin)
        external
        returns (uint256);

    function _acceptAdmin() external returns (uint256);

    function _setComptroller(IComptroller newComptroller)
        external
        returns (uint256);

    function _setReserveFactor(uint256 newReserveFactorMantissa)
        external
        returns (uint256);

    function _reduceReserves(uint256 reduceAmount) external returns (uint256);

    function _setInterestRateModel(InterestRateModel newInterestRateModel)
        external
        returns (uint256);
}


// Part: ComptrollerV2Storage

interface ComptrollerV2Storage is ComptrollerV1Storage {
    enum Version {VANILLA, COLLATERALCAP, WRAPPEDNATIVE}

    struct Market {
        bool isListed;
        uint256 collateralFactorMantissa;
        mapping(address => bool) accountMembership;
        bool isComped;
        Version version;
    }

    /**
     * @notice Official mapping of cTokens -> Market metadata
     * @dev Used e.g. to determine if a market is supported
     */
    // mapping(address => Market) external markets;
    // function markets(address) external view returns (Market);

    /**
     * @notice The Pause Guardian can pause certain actions as a safety mechanism.
     *  Actions which allow users to remove their own assets cannot be paused.
     *  Liquidation / seizing / transfer can only be paused globally, not by market.
     */
    // address external pauseGuardian;
    // bool external _mintGuardianPaused;
    // bool external _borrowGuardianPaused;
    // bool external transferGuardianPaused;
    // bool external seizeGuardianPaused;
    // mapping(address => bool) external mintGuardianPaused;
    // mapping(address => bool) external borrowGuardianPaused;
}

// Part: ICTokenErc20

interface ICTokenErc20 is ICToken {
    /*** User Interface ***/

    function mint(uint256 mintAmount) external returns (uint256);

    function redeem(uint256 redeemTokens) external returns (uint256);

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);

    function borrow(uint256 borrowAmount) external returns (uint256);

    function repayBorrow(uint256 repayAmount) external returns (uint256);

    function liquidateBorrow(
        address borrower,
        uint256 repayAmount,
        ICToken cTokenCollateral
    ) external returns (uint256);

    /*** Admin Functions ***/

    function _addReserves(uint256 addAmount) external returns (uint256);
}

// Part: ComptrollerV3Storage

interface ComptrollerV3Storage is ComptrollerV2Storage {
    // struct CompMarketState {
    //     /// @notice The market's last updated compBorrowIndex or compSupplyIndex
    //     uint224 index;
    //     /// @notice The block number the index was last updated at
    //     uint32 block;
    // }
    // /// @notice A list of all markets
    // CToken[] external allMarkets;
    // /// @notice The rate at which the flywheel distributes COMP, per block
    // uint external compRate;
    // /// @notice The portion of compRate that each market currently receives
    // mapping(address => uint) external compSpeeds;
    // /// @notice The COMP market supply state for each market
    // mapping(address => CompMarketState) external compSupplyState;
    // /// @notice The COMP market borrow state for each market
    // mapping(address => CompMarketState) external compBorrowState;
    // /// @notice The COMP borrow index for each market for each supplier as of the last time they accrued COMP
    // mapping(address => mapping(address => uint)) external compSupplierIndex;
    // /// @notice The COMP borrow index for each market for each borrower as of the last time they accrued COMP
    // mapping(address => mapping(address => uint)) external compBorrowerIndex;
    // /// @notice The COMP accrued but not yet transferred to each user
    // mapping(address => uint) external compAccrued;
}

// Part: CoreStrategy


// Part: ComptrollerV4Storage

interface ComptrollerV4Storage is ComptrollerV3Storage {
    // @notice The borrowCapGuardian can set borrowCaps to any number for any market. Lowering the borrow cap could disable borrowing on the given market.
    // address external borrowCapGuardian;
    function borrowCapGuardian() external view returns (address);

    // @notice Borrow caps enforced by borrowAllowed for each cToken address. Defaults to zero which corresponds to unlimited borrowing.
    // mapping(address => uint) external borrowCaps;
    function borrowCaps(address) external view returns (uint256);
}

// Part: ComptrollerV5Storage

interface ComptrollerV5Storage is ComptrollerV4Storage {
    // @notice The supplyCapGuardian can set supplyCaps to any number for any market. Lowering the supply cap could disable supplying to the given market.
    // address external supplyCapGuardian;
    function supplyCapGuardian() external view returns (address);

    // @notice Supply caps enforced by mintAllowed for each cToken address. Defaults to zero which corresponds to unlimited supplying.
    // mapping(address => uint) external supplyCaps;
    function supplyCaps(address) external view returns (uint256);
}

// Part: ScreamPriceOracle

contract ScreamPriceOracle is IPriceOracle {
    using SafeMath for uint256;

    address cTokenQuote;
    address cTokenBase;
    ICompPriceOracle oracle;

    constructor(
        address _comtroller,
        address _cTokenQuote,
        address _cTokenBase
    ) public {
        cTokenQuote = _cTokenQuote;
        cTokenBase = _cTokenBase;
        oracle = ICompPriceOracle(ComptrollerV5Storage(_comtroller).oracle());
        require(oracle.isPriceOracle());
    }

    function getPrice() external view override returns (uint256) {
        // If price returns 0, the price is not available
        uint256 quotePrice = oracle.getUnderlyingPrice(cTokenQuote);
        require(quotePrice != 0);

        uint256 basePrice = oracle.getUnderlyingPrice(cTokenBase);
        require(basePrice != 0);

        return basePrice.mul(1e18).div(quotePrice);
    }
}

interface IFarmMasterChef {
    function deposit(uint256 _pid, uint256 _amount) external;

    function withdraw(uint256 _pid, uint256 _amount) external;

    function userInfo(uint256 _pid, address user)
        external
        view
        returns (UserInfo calldata);
}