// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {MarketParams, Position} from "./IMorpho.sol";

/// @notice 期权保护参数
struct CollarParams {
    uint256 putStrike; // 看跌期权执行价
    uint256 callStrike; // 看涨期权执行价
    uint256 expiry; // 到期时间
    uint256 premiumPaid; // 已支付权利金
    bool isActive; // 是否激活
    uint256 collateralAmount; // 受保护的抵押品数量
}

/// @notice 期权保护收益分配
struct ProtectionGains {
    uint256 userShare; // 用户份额 (75%)
    uint256 protocolShare; // 协议份额 (25%)
    uint256 totalAmount; // 总金额
    uint256 unlockTime; // 解锁时间
}

/// @title IVolcube
/// @author Volcube Labs
/// @notice Volcube 增强型借贷协议接口：支持更高 LLTV + 零成本领口期权保护
interface IVolcube {
    /* EVENTS */

    event MarketCreated(bytes32 indexed marketId, MarketParams marketParams);
    event Supply(
        bytes32 indexed marketId, address indexed supplier, address indexed onBehalf, uint256 assets, uint256 shares
    );
    event Withdraw(
        bytes32 indexed marketId,
        address indexed withdrawer,
        address indexed onBehalf,
        address indexed receiver,
        uint256 assets,
        uint256 shares
    );
    event Borrow(
        bytes32 indexed marketId,
        address indexed borrower,
        address indexed onBehalf,
        address indexed receiver,
        uint256 assets,
        uint256 shares
    );
    event Repay(
        bytes32 indexed marketId, address indexed repayer, address indexed onBehalf, uint256 assets, uint256 shares
    );
    event SupplyCollateral(
        bytes32 indexed marketId, address indexed supplier, address indexed onBehalf, uint256 assets
    );
    event WithdrawCollateral(
        bytes32 indexed marketId,
        address indexed withdrawer,
        address indexed onBehalf,
        address indexed receiver,
        uint256 assets
    );
    event Liquidate(
        bytes32 indexed marketId,
        address indexed liquidator,
        address indexed borrower,
        uint256 repaidAssets,
        uint256 repaidShares,
        uint256 seizedAssets
    );

    // 期权相关事件
    event CollarProtectionCreated(
        bytes32 indexed marketId, address indexed user, uint256 putStrike, uint256 callStrike, uint256 expiry
    );
    event PutOptionTriggered(
        bytes32 indexed marketId, address indexed user, uint256 protectionAmount, uint256 userGain, uint256 protocolGain
    );
    event CallOptionExercised(
        bytes32 indexed marketId, address indexed user, uint256 collateralSold, uint256 usdcReceived, uint256 userProfit
    );
    event ProtectionGainsWithdrawn(bytes32 indexed marketId, address indexed user, uint256 amount);

    /* ERRORS */

    error ZeroAddress();
    error Unauthorized();
    error MarketNotCreated();
    error MarketAlreadyCreated();
    error InsufficientCollateral();
    error InsufficientLiquidity();
    error HealthyPosition();
    error ZeroAssets();
    error ZeroShares();
    error InconsistentInput();
    error CollarAlreadyActive();
    error CollarNotActive();
    error ProtectionStillLocked();
    error InvalidStrikePrice();
    error OptionExpired();

    /* ADMIN FUNCTIONS */

    function setOwner(address newOwner) external;
    function setFeeRecipient(address newFeeRecipient) external;
    function enableIrm(address irm) external;

    /* MARKET CREATION */

    function createMarket(MarketParams memory marketParams) external;

    /* ENHANCED BORROWING WITH COLLAR PROTECTION */

    /// @notice 核心功能：创建高杠杆借款 + 期权保护
    function borrowWithCollarProtection(
        MarketParams memory marketParams,
        uint256 collateralAmount,
        uint256 borrowAmount,
        uint256 putStrike,
        uint256 callStrike,
        uint256 duration
    ) external returns (uint256 actualBorrowed);

    /// @notice 监控和触发期权保护
    function monitorAndProtect(MarketParams memory marketParams, address user) external;

    /* STANDARD LENDING FUNCTIONS */

    function supply(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf)
        external
        returns (uint256, uint256);

    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256);

    function repay(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf)
        external
        returns (uint256, uint256);

    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf) external;

    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external;

    /* VIEW FUNCTIONS */

    /// @notice 检查用户是否健康
    function isHealthy(MarketParams memory marketParams, address user) external view returns (bool);

    /// @notice 获取用户最大借款金额
    function getMaxBorrow(MarketParams memory marketParams, address user) external view returns (uint256);

    /// @notice 获取用户当前 LTV
    function getCurrentLTV(MarketParams memory marketParams, address user) external view returns (uint256);

    /// @notice 获取市场信息
    function getMarket(bytes32 marketId)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );

    /// @notice 获取用户仓位
    function getPosition(bytes32 marketId, address user)
        external
        view
        returns (uint128 supplyShares, uint128 borrowShares, uint128 collateral);

    /// @notice 获取用户期权保护参数
    function getUserCollarProtection(bytes32 marketId, address user) external view returns (CollarParams memory);

    /// @notice 获取用户保护收益
    function getUserProtectionGains(bytes32 marketId, address user) external view returns (ProtectionGains memory);

    /* USER FUNCTIONS */

    /// @notice 提取保护收益
    function withdrawProtectionGains(MarketParams memory marketParams) external;

    /// @notice 设置授权
    function setAuthorization(address authorized, bool isAuthorized) external;
}
