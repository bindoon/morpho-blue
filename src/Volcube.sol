// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {IERC20} from "./interfaces/IERC20.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {IVolcube, CollarParams, ProtectionGains} from "./interfaces/IVolcube.sol";
import {MarketParams, Position, Market} from "./interfaces/IMorpho.sol";

import "./libraries/ConstantsLib.sol";
import {UtilsLib} from "./libraries/UtilsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {MathLib, WAD} from "./libraries/MathLib.sol";
import {SharesMathLib} from "./libraries/SharesMathLib.sol";
import {MarketParamsLib} from "./libraries/MarketParamsLib.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";

/// @title Volcube
/// @author Volcube Labs
/// @notice Volcube 增强型借贷协议：支持更高 LLTV + 零成本领口期权保护
contract Volcube is IVolcube {
    using MathLib for uint128;
    using MathLib for uint256;
    using UtilsLib for uint256;
    using SharesMathLib for uint256;
    using SafeTransferLib for IERC20;
    using MarketParamsLib for MarketParams;

    /* STORAGE */

    /// @notice 合约所有者
    address public owner;

    /// @notice 手续费接收者
    address public feeRecipient;

    /// @notice 期权交易所地址
    address public optionsExchange;

    /// @notice DEX 路由器地址
    address public dexRouter;

    /// @notice 市场 ID 到市场参数的映射
    mapping(bytes32 => MarketParams) public idToMarketParams;

    /// @notice 市场状态映射
    mapping(bytes32 => Market) public market;

    /// @notice 用户仓位映射 market_id => user => position
    mapping(bytes32 => mapping(address => Position)) public position;

    /// @notice 用户期权保护映射 market_id => user => collar_params
    mapping(bytes32 => mapping(address => CollarParams)) public userCollarProtection;

    /// @notice 用户保护收益映射 market_id => user => protection_gains
    mapping(bytes32 => mapping(address => ProtectionGains)) public userProtectionGains;

    /// @notice 授权映射
    mapping(address => mapping(address => bool)) public isAuthorized;

    /// @notice 已启用的利率模型
    mapping(address => bool) public isIrmEnabled;

    /// @notice 已启用的 LLTV
    mapping(uint256 => bool) public isLltvEnabled;

    /// @notice 保护收益分配比例 (用户75%, 协议25%)
    uint256 public constant USER_PROTECTION_SHARE = 75e16; // 75%

    /// @notice 保护收益锁定期 (30天)
    uint256 public constant PROTECTION_LOCK_PERIOD = 30 days;

    /* MODIFIERS */

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier marketExists(bytes32 marketId) {
        if (market[marketId].lastUpdate == 0) revert MarketNotCreated();
        _;
    }

    modifier isAuthorizedUser(address onBehalf) {
        if (msg.sender != onBehalf && !isAuthorized[onBehalf][msg.sender]) revert Unauthorized();
        _;
    }

    /* CONSTRUCTOR */

    constructor(address _owner, address _feeRecipient, address _optionsExchange, address _dexRouter) {
        if (_owner == address(0) || _feeRecipient == address(0)) revert ZeroAddress();

        owner = _owner;
        feeRecipient = _feeRecipient;
        optionsExchange = _optionsExchange;
        dexRouter = _dexRouter;
    }

    /* ADMIN FUNCTIONS */

    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newFeeRecipient;
    }

    function enableIrm(address irm) external onlyOwner {
        isIrmEnabled[irm] = true;
    }

    function enableLltv(uint256 lltv) external onlyOwner {
        require(lltv < WAD, "LLTV_TOO_HIGH");
        isLltvEnabled[lltv] = true;
    }

    /* MARKET CREATION */

    function createMarket(MarketParams memory marketParams) external {
        bytes32 marketId = _getMarketId(marketParams);

        if (market[marketId].lastUpdate != 0) revert MarketAlreadyCreated();
        if (!isIrmEnabled[marketParams.irm]) revert Unauthorized();
        if (!isLltvEnabled[marketParams.lltv]) revert Unauthorized();

        market[marketId].lastUpdate = uint128(block.timestamp);
        idToMarketParams[marketId] = marketParams;

        emit MarketCreated(marketId, marketParams);
    }

    /* ENHANCED BORROWING WITH COLLAR PROTECTION */

    /// @notice 核心功能：创建高杠杆借款 + 期权保护
    function borrowWithCollarProtection(
        MarketParams memory marketParams,
        uint256 collateralAmount,
        uint256 borrowAmount,
        uint256 putStrike,
        uint256 callStrike,
        uint256 duration
    ) external returns (uint256 actualBorrowed) {
        bytes32 marketId = _getMarketId(marketParams);

        if (market[marketId].lastUpdate == 0) revert MarketNotCreated();
        if (userCollarProtection[marketId][msg.sender].isActive) revert CollarAlreadyActive();

        // 验证期权参数
        uint256 currentPrice = IOracle(marketParams.oracle).price();
        if (putStrike >= currentPrice || callStrike <= currentPrice) revert InvalidStrikePrice();
        if (duration == 0 || duration > 365 days) revert InvalidStrikePrice();

        // 1. 先供应抵押品
        _supplyCollateral(marketParams, marketId, collateralAmount, msg.sender);

        // 2. 验证借款数量在市场LLTV范围内
        uint256 maxBorrow = _calculateMaxBorrow(marketParams, marketId, msg.sender, currentPrice);
        if (borrowAmount > maxBorrow) revert InsufficientCollateral();

        // 3. 创建期权保护
        _createCollarProtection(marketId, msg.sender, putStrike, callStrike, duration, collateralAmount);

        // 4. 执行借款
        actualBorrowed = _borrow(marketParams, marketId, borrowAmount, msg.sender, msg.sender);

        return actualBorrowed;
    }

    /// @notice 监控和触发期权保护
    function monitorAndProtect(MarketParams memory marketParams, address user) external {
        bytes32 marketId = _getMarketId(marketParams);
        CollarParams storage collar = userCollarProtection[marketId][user];

        if (!collar.isActive) revert CollarNotActive();
        if (block.timestamp > collar.expiry) revert OptionExpired();

        uint256 currentPrice = IOracle(marketParams.oracle).price();

        // 检查看跌期权触发
        if (currentPrice <= collar.putStrike) {
            _triggerPutProtection(marketParams, marketId, user, currentPrice);
        }

        // 检查看涨期权行权
        if (currentPrice >= collar.callStrike) {
            _executeCallExercise(marketParams, marketId, user, currentPrice);
        }
    }

    /* STANDARD LENDING FUNCTIONS */

    function supply(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf)
        external
        isAuthorizedUser(onBehalf)
        returns (uint256, uint256)
    {
        bytes32 marketId = _getMarketId(marketParams);
        if (market[marketId].lastUpdate == 0) revert MarketNotCreated();
        if (!_exactlyOneZero(assets, shares)) revert InconsistentInput();
        if (onBehalf == address(0)) revert ZeroAddress();

        _accrueInterest(marketParams, marketId);

        if (assets > 0) {
            shares = assets.toSharesDown(market[marketId].totalSupplyAssets, market[marketId].totalSupplyShares);
        } else {
            assets = shares.toAssetsUp(market[marketId].totalSupplyAssets, market[marketId].totalSupplyShares);
        }

        position[marketId][onBehalf].supplyShares += uint128(shares);
        market[marketId].totalSupplyShares += uint128(shares);
        market[marketId].totalSupplyAssets += uint128(assets);

        emit Supply(marketId, msg.sender, onBehalf, assets, shares);

        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        return (assets, shares);
    }

    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external isAuthorizedUser(onBehalf) returns (uint256, uint256) {
        bytes32 marketId = _getMarketId(marketParams);
        uint256 borrowAmount = assets > 0
            ? assets
            : shares.toAssetsDown(market[marketId].totalBorrowAssets, market[marketId].totalBorrowShares);
        return (_borrow(marketParams, marketId, borrowAmount, onBehalf, receiver), 0);
    }

    function repay(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf)
        external
        returns (uint256, uint256)
    {
        bytes32 marketId = _getMarketId(marketParams);
        if (market[marketId].lastUpdate == 0) revert MarketNotCreated();
        if (!_exactlyOneZero(assets, shares)) revert InconsistentInput();
        if (onBehalf == address(0)) revert ZeroAddress();

        _accrueInterest(marketParams, marketId);

        if (assets > 0) {
            shares = assets.toSharesDown(market[marketId].totalBorrowAssets, market[marketId].totalBorrowShares);
        } else {
            assets = shares.toAssetsUp(market[marketId].totalBorrowAssets, market[marketId].totalBorrowShares);
        }

        position[marketId][onBehalf].borrowShares -= uint128(shares);
        market[marketId].totalBorrowShares -= uint128(shares);
        market[marketId].totalBorrowAssets =
            UtilsLib.zeroFloorSub(market[marketId].totalBorrowAssets, assets).toUint128();

        emit Repay(marketId, msg.sender, onBehalf, assets, shares);

        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        return (assets, shares);
    }

    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf) external {
        bytes32 marketId = _getMarketId(marketParams);
        _supplyCollateral(marketParams, marketId, assets, onBehalf);
    }

    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external
        isAuthorizedUser(onBehalf)
    {
        bytes32 marketId = _getMarketId(marketParams);
        if (market[marketId].lastUpdate == 0) revert MarketNotCreated();
        if (assets == 0) revert ZeroAssets();
        if (receiver == address(0)) revert ZeroAddress();

        _accrueInterest(marketParams, marketId);

        position[marketId][onBehalf].collateral -= uint128(assets);

        if (!_isHealthy(marketParams, marketId, onBehalf)) revert InsufficientCollateral();

        emit WithdrawCollateral(marketId, msg.sender, onBehalf, receiver, assets);

        IERC20(marketParams.collateralToken).safeTransfer(receiver, assets);
    }

    /* INTERNAL HELPER FUNCTIONS */

    function _createCollarProtection(
        bytes32 marketId,
        address user,
        uint256 putStrike,
        uint256 callStrike,
        uint256 duration,
        uint256 collateralAmount
    ) internal {
        uint256 expiry = block.timestamp + duration;

        // 计算期权权利金 (简化版本，实际应该调用期权定价模型)
        uint256 putPremium = _calculateOptionPremium(putStrike, duration, true);
        uint256 callPremium = _calculateOptionPremium(callStrike, duration, false);

        // 零成本领口：看涨权利金应该大致等于看跌权利金
        uint256 netPremium = putPremium > callPremium ? putPremium - callPremium : 0;

        // 创建期权保护记录
        userCollarProtection[marketId][user] = CollarParams({
            putStrike: putStrike,
            callStrike: callStrike,
            expiry: expiry,
            premiumPaid: netPremium,
            isActive: true,
            collateralAmount: collateralAmount
        });

        emit CollarProtectionCreated(marketId, user, putStrike, callStrike, expiry);
    }

    function _triggerPutProtection(
        MarketParams memory marketParams,
        bytes32 marketId,
        address user,
        uint256 currentPrice
    ) internal {
        CollarParams storage collar = userCollarProtection[marketId][user];

        // 计算保护金额
        uint256 priceDiff = collar.putStrike - currentPrice;
        uint256 protectionAmount = (collar.collateralAmount * priceDiff) / collar.putStrike;

        // 分配保护收益：75% 给用户，25% 给协议
        uint256 userGain = (protectionAmount * USER_PROTECTION_SHARE) / WAD;
        uint256 protocolGain = protectionAmount - userGain;

        // 记录保护收益
        userProtectionGains[marketId][user] = ProtectionGains({
            userShare: userGain,
            protocolShare: protocolGain,
            totalAmount: protectionAmount,
            unlockTime: block.timestamp + PROTECTION_LOCK_PERIOD
        });

        // 将用户份额的保护收益转换为抵押品追加
        _addProtectionCollateral(marketParams, marketId, user, userGain);

        emit PutOptionTriggered(marketId, user, protectionAmount, userGain, protocolGain);
    }

    function _executeCallExercise(
        MarketParams memory marketParams,
        bytes32 marketId,
        address user,
        uint256 currentPrice
    ) internal {
        CollarParams storage collar = userCollarProtection[marketId][user];
        Position storage pos = position[marketId][user];

        // 1. 计算收益
        uint256 totalCollateral = pos.collateral;
        uint256 usdcReceived = (totalCollateral * collar.callStrike) / WAD;

        // 2. 计算借款金额
        uint256 borrowedAmount =
            uint256(pos.borrowShares).toAssetsUp(market[marketId].totalBorrowAssets, market[marketId].totalBorrowShares);

        // 3. 提取抵押品
        pos.collateral = 0;

        // 4. 偿还借款
        if (borrowedAmount > 0) {
            pos.borrowShares = 0;
            market[marketId].totalBorrowShares -= uint128(
                borrowedAmount.toSharesUp(market[marketId].totalBorrowAssets, market[marketId].totalBorrowShares)
            );
            market[marketId].totalBorrowAssets -= uint128(borrowedAmount);
        }

        // 5. 用户获得剩余资金
        uint256 userProfit = usdcReceived - borrowedAmount;

        // 6. 策略终止
        collar.isActive = false;

        emit CallOptionExercised(marketId, user, totalCollateral, usdcReceived, userProfit);

        // 转账给用户
        IERC20(marketParams.loanToken).safeTransfer(user, userProfit);
    }

    function _addProtectionCollateral(
        MarketParams memory marketParams,
        bytes32 marketId,
        address user,
        uint256 additionalAmount
    ) internal {
        // 将 USDC 保护收益转换为 ETH 并追加为抵押品
        // 这里简化处理，实际需要通过 DEX 进行交换
        uint256 currentPrice = IOracle(marketParams.oracle).price();
        uint256 additionalCollateral = (additionalAmount * ORACLE_PRICE_SCALE) / currentPrice;

        position[marketId][user].collateral += uint128(additionalCollateral);

        emit SupplyCollateral(marketId, address(this), user, additionalCollateral);
    }

    function _borrow(
        MarketParams memory marketParams,
        bytes32 marketId,
        uint256 assets,
        address onBehalf,
        address receiver
    ) internal marketExists(marketId) returns (uint256) {
        if (assets == 0) revert ZeroAssets();
        if (receiver == address(0)) revert ZeroAddress();

        _accrueInterest(marketParams, marketId);

        uint256 shares = assets.toSharesUp(market[marketId].totalBorrowAssets, market[marketId].totalBorrowShares);

        position[marketId][onBehalf].borrowShares += uint128(shares);
        market[marketId].totalBorrowShares += uint128(shares);
        market[marketId].totalBorrowAssets += uint128(assets);

        // 使用市场的 LLTV 检查健康度
        if (!_isHealthy(marketParams, marketId, onBehalf)) revert InsufficientCollateral();
        if (market[marketId].totalBorrowAssets > market[marketId].totalSupplyAssets) revert InsufficientLiquidity();

        emit Borrow(marketId, msg.sender, onBehalf, receiver, assets, shares);

        IERC20(marketParams.loanToken).safeTransfer(receiver, assets);

        return assets;
    }

    function _supplyCollateral(MarketParams memory marketParams, bytes32 marketId, uint256 assets, address onBehalf)
        internal
    {
        if (assets == 0) revert ZeroAssets();

        position[marketId][onBehalf].collateral += uint128(assets);

        emit SupplyCollateral(marketId, msg.sender, onBehalf, assets);

        IERC20(marketParams.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    function _isHealthy(MarketParams memory marketParams, bytes32 marketId, address user)
        internal
        view
        returns (bool)
    {
        Position memory pos = position[marketId][user];
        if (pos.borrowShares == 0) return true;

        uint256 collateralPrice = IOracle(marketParams.oracle).price();

        uint256 borrowed =
            uint256(pos.borrowShares).toAssetsUp(market[marketId].totalBorrowAssets, market[marketId].totalBorrowShares);
        uint256 maxBorrow = (uint256(pos.collateral) * collateralPrice * marketParams.lltv) / (ORACLE_PRICE_SCALE * WAD);

        return maxBorrow >= borrowed;
    }

    function _calculateMaxBorrow(
        MarketParams memory marketParams,
        bytes32 marketId,
        address user,
        uint256 collateralPrice
    ) internal view returns (uint256) {
        uint256 collateral = position[marketId][user].collateral;
        return (collateral * collateralPrice * marketParams.lltv) / (ORACLE_PRICE_SCALE * WAD);
    }

    function _accrueInterest(MarketParams memory marketParams, bytes32 marketId) internal {
        uint256 elapsed = block.timestamp - market[marketId].lastUpdate;
        if (elapsed == 0) return;

        // 简化的利息计算
        if (marketParams.irm != address(0)) {
            uint256 borrowRate = 5e16; // 5% 年化利率 (简化)
            uint256 interest = (market[marketId].totalBorrowAssets * borrowRate * elapsed) / (365 days * WAD);

            market[marketId].totalBorrowAssets += uint128(interest);
            market[marketId].totalSupplyAssets += uint128(interest);
        }

        market[marketId].lastUpdate = uint128(block.timestamp);
    }

    /* UTILITY FUNCTIONS */

    function _getMarketId(MarketParams memory marketParams) internal pure returns (bytes32) {
        return marketParams.id();
    }

    function _exactlyOneZero(uint256 assets, uint256 shares) internal pure returns (bool) {
        return (assets == 0) != (shares == 0);
    }

    function _calculateOptionPremium(uint256 strike, uint256 duration, bool isPut) internal view returns (uint256) {
        // 简化的期权定价 (实际应该使用 Black-Scholes 或类似模型)
        uint256 timeValue = (strike * duration * 20e16) / (365 days * WAD); // 2% 年化时间价值
        return timeValue;
    }

    /* PUBLIC VIEW FUNCTIONS */

    /// @notice 检查用户是否健康
    function isHealthy(MarketParams memory marketParams, address user) public view returns (bool) {
        bytes32 marketId = _getMarketId(marketParams);
        return _isHealthy(marketParams, marketId, user);
    }

    /// @notice 获取用户最大借款金额
    function getMaxBorrow(MarketParams memory marketParams, address user) public view returns (uint256) {
        bytes32 marketId = _getMarketId(marketParams);
        uint256 collateralPrice = IOracle(marketParams.oracle).price();
        return _calculateMaxBorrow(marketParams, marketId, user, collateralPrice);
    }

    /// @notice 获取用户当前 LTV
    function getCurrentLTV(MarketParams memory marketParams, address user) public view returns (uint256) {
        bytes32 marketId = _getMarketId(marketParams);
        Position memory pos = position[marketId][user];

        if (pos.borrowShares == 0) return 0;

        uint256 collateralPrice = IOracle(marketParams.oracle).price();
        uint256 borrowed =
            uint256(pos.borrowShares).toAssetsUp(market[marketId].totalBorrowAssets, market[marketId].totalBorrowShares);
        uint256 collateralValue = (uint256(pos.collateral) * collateralPrice) / ORACLE_PRICE_SCALE;

        return collateralValue == 0 ? type(uint256).max : (borrowed * WAD) / collateralValue;
    }

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
        )
    {
        Market memory m = market[marketId];
        return (m.totalSupplyAssets, m.totalSupplyShares, m.totalBorrowAssets, m.totalBorrowShares, m.lastUpdate, m.fee);
    }

    /// @notice 获取用户仓位
    function getPosition(bytes32 marketId, address user)
        external
        view
        returns (uint128 supplyShares, uint128 borrowShares, uint128 collateral)
    {
        Position memory pos = position[marketId][user];
        return (pos.supplyShares, pos.borrowShares, pos.collateral);
    }

    /// @notice 获取用户期权保护参数
    function getUserCollarProtection(bytes32 marketId, address user) external view returns (CollarParams memory) {
        return userCollarProtection[marketId][user];
    }

    /// @notice 获取用户保护收益
    function getUserProtectionGains(bytes32 marketId, address user) external view returns (ProtectionGains memory) {
        return userProtectionGains[marketId][user];
    }

    /* USER FUNCTIONS */

    /// @notice 提取保护收益
    function withdrawProtectionGains(MarketParams memory marketParams) external {
        bytes32 marketId = _getMarketId(marketParams);
        ProtectionGains storage gains = userProtectionGains[marketId][msg.sender];

        if (gains.userShare == 0) revert ZeroAssets();
        if (block.timestamp < gains.unlockTime) revert ProtectionStillLocked();

        uint256 amount = gains.userShare;
        gains.userShare = 0;

        emit ProtectionGainsWithdrawn(marketId, msg.sender, amount);

        IERC20(marketParams.loanToken).safeTransfer(msg.sender, amount);
    }

    /// @notice 设置授权
    function setAuthorization(address authorized, bool isAuthorized_) external {
        isAuthorized[msg.sender][authorized] = isAuthorized_;
    }
}
