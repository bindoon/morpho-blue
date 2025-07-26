// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {IMorpho} from "./src/interfaces/IMorpho.sol";
import {IMorphoCallbacks} from "./src/interfaces/IMorphoCallbacks.sol";
import {IERC20} from "./src/interfaces/IERC20.sol";
import {IOracle} from "./src/interfaces/IOracle.sol";
import {MathLib, WAD} from "./src/libraries/MathLib.sol";

/// @title ZeroCostCollarStrategy
/// @notice 零成本领口期权策略合约，用于保护 Morpho Blue 借款人的清算风险
/// @dev 通过买入看跌期权和卖出看涨期权实现零成本保护
contract ZeroCostCollarStrategy is
    IMorphoCallbacks.IMorphoSupplyCollateralCallback,
    IMorphoCallbacks.IMorphoRepayCallback,
    IMorphoCallbacks.IMorphoLiquidateCallback
{
    using MathLib for uint256;

    // ============ 状态变量 ============

    IMorpho public immutable morpho;
    address public immutable owner;

    // 期权参数
    struct CollarParams {
        uint256 putStrikePrice; // 看跌期权执行价
        uint256 callStrikePrice; // 看涨期权执行价
        uint256 putPremium; // 看跌期权权利金
        uint256 callPremium; // 看涨期权权利金
        uint256 expirationTime; // 期权到期时间
        bool isActive; // 策略是否激活
    }

    // 用户策略映射
    mapping(address => mapping(bytes32 => CollarParams)) public userCollars;

    // 期权交易所接口（示例）
    address public optionExchange;

    // 事件
    event CollarCreated(
        address indexed user,
        bytes32 indexed marketId,
        uint256 putStrikePrice,
        uint256 callStrikePrice,
        uint256 putPremium,
        uint256 callPremium,
        uint256 expirationTime
    );

    event CollarExecuted(
        address indexed user,
        bytes32 indexed marketId,
        bool isPutExecuted,
        uint256 executedAmount,
        uint256 collateralValue
    );

    event CollarExpired(address indexed user, bytes32 indexed marketId, uint256 refundAmount);

    // ============ 构造函数 ============

    constructor(IMorpho _morpho, address _optionExchange) {
        morpho = _morpho;
        optionExchange = _optionExchange;
        owner = msg.sender;
    }

    // ============ 核心策略函数 ============

    /// @notice 创建零成本领口策略
    /// @param marketParams 市场参数
    /// @param collateralAmount 抵押品数量
    /// @param putStrikePrice 看跌期权执行价
    /// @param callStrikePrice 看涨期权执行价
    /// @param duration 策略持续时间（秒）
    function createCollar(
        IMorpho.MarketParams memory marketParams,
        uint256 collateralAmount,
        uint256 putStrikePrice,
        uint256 callStrikePrice,
        uint256 duration
    ) external {
        bytes32 marketId = _getMarketId(marketParams);

        // 验证参数
        require(putStrikePrice < callStrikePrice, "Invalid strike prices");
        require(duration > 0, "Invalid duration");

        // 计算期权权利金（这里简化处理，实际需要与期权交易所交互）
        (uint256 putPremium, uint256 callPremium) = _calculatePremiums(
            marketParams.collateralToken, collateralAmount, putStrikePrice, callStrikePrice, duration
        );

        // 验证零成本条件
        require(callPremium >= putPremium, "Not zero-cost");

        // 存储策略参数
        userCollars[msg.sender][marketId] = CollarParams({
            putStrikePrice: putStrikePrice,
            callStrikePrice: callStrikePrice,
            putPremium: putPremium,
            callPremium: callPremium,
            expirationTime: block.timestamp + duration,
            isActive: true
        });

        // 执行期权交易（简化实现）
        _executeOptionTrades(
            marketParams.collateralToken, collateralAmount, putStrikePrice, callStrikePrice, putPremium, callPremium
        );

        // 供应抵押品到 Morpho
        _supplyCollateralWithCallback(marketParams, collateralAmount);

        emit CollarCreated(
            msg.sender, marketId, putStrikePrice, callStrikePrice, putPremium, callPremium, block.timestamp + duration
        );
    }

    /// @notice 检查并执行期权策略
    /// @param marketParams 市场参数
    /// @param user 用户地址
    function checkAndExecuteCollar(IMorpho.MarketParams memory marketParams, address user) external {
        bytes32 marketId = _getMarketId(marketParams);
        CollarParams storage collar = userCollars[user][marketId];

        require(collar.isActive, "Collar not active");
        require(block.timestamp < collar.expirationTime, "Collar expired");

        // 获取当前抵押品价格
        uint256 currentPrice = IOracle(marketParams.oracle).price();

        // 检查是否需要执行看跌期权
        if (currentPrice < collar.putStrikePrice) {
            _executePutOption(marketParams, user, currentPrice);
        }

        // 检查是否需要执行看涨期权
        if (currentPrice > collar.callStrikePrice) {
            _executeCallOption(marketParams, user, currentPrice);
        }
    }

    /// @notice 关闭领口策略
    /// @param marketParams 市场参数
    function closeCollar(IMorpho.MarketParams memory marketParams) external {
        bytes32 marketId = _getMarketId(marketParams);
        CollarParams storage collar = userCollars[msg.sender][marketId];

        require(collar.isActive, "Collar not active");

        // 关闭期权头寸
        _closeOptionPositions(marketParams.collateralToken);

        // 标记策略为非激活
        collar.isActive = false;

        // 提取抵押品
        _withdrawCollateral(marketParams);
    }

    // ============ 回调函数实现 ============

    /// @notice 抵押品供应回调
    function onMorphoSupplyCollateral(uint256 assets, bytes calldata data) external override {
        require(msg.sender == address(morpho), "Unauthorized");

        // 处理抵押品供应后的逻辑
        // 例如：记录策略状态、更新风险参数等
    }

    /// @notice 还款回调
    function onMorphoRepay(uint256 assets, bytes calldata data) external override {
        require(msg.sender == address(morpho), "Unauthorized");

        // 处理还款后的逻辑
        // 例如：检查是否需要调整期权策略
    }

    /// @notice 清算回调
    function onMorphoLiquidate(uint256 repaidAssets, bytes calldata data) external override {
        require(msg.sender == address(morpho), "Unauthorized");

        // 处理清算事件
        // 例如：自动执行看跌期权保护剩余抵押品
        _handleLiquidationCallback(repaidAssets, data);
    }

    // ============ 内部函数 ============

    /// @notice 计算期权权利金
    function _calculatePremiums(
        address collateralToken,
        uint256 collateralAmount,
        uint256 putStrikePrice,
        uint256 callStrikePrice,
        uint256 duration
    ) internal view returns (uint256 putPremium, uint256 callPremium) {
        // 这里简化实现，实际需要与期权定价模型交互
        // 可以使用 Black-Scholes 模型或其他定价方法

        uint256 volatility = 0.5e18; // 50% 年化波动率
        uint256 riskFreeRate = 0.05e18; // 5% 无风险利率

        // 简化的期权定价（实际需要更复杂的模型）
        putPremium = collateralAmount * volatility * duration / (365 days * WAD);
        callPremium = collateralAmount * volatility * duration / (365 days * WAD);

        // 调整使 callPremium >= putPremium（零成本条件）
        if (callPremium < putPremium) {
            callPremium = putPremium;
        }
    }

    /// @notice 执行期权交易
    function _executeOptionTrades(
        address collateralToken,
        uint256 collateralAmount,
        uint256 putStrikePrice,
        uint256 callStrikePrice,
        uint256 putPremium,
        uint256 callPremium
    ) internal {
        // 这里需要与实际的期权交易所交互
        // 1. 买入看跌期权
        // 2. 卖出看涨期权
        // 3. 支付/收取权利金

        // 简化实现：直接转移代币
        IERC20(collateralToken).transferFrom(msg.sender, address(this), putPremium);
        IERC20(collateralToken).transfer(msg.sender, callPremium);
    }

    /// @notice 执行看跌期权
    function _executePutOption(IMorpho.MarketParams memory marketParams, address user, uint256 currentPrice) internal {
        bytes32 marketId = _getMarketId(marketParams);
        CollarParams storage collar = userCollars[user][marketId];

        // 计算执行收益
        uint256 strikePrice = collar.putStrikePrice;
        uint256 executionValue = (strikePrice - currentPrice) * WAD / currentPrice;

        // 执行看跌期权保护
        _executeProtection(marketParams, user, executionValue, true);

        emit CollarExecuted(user, marketId, true, executionValue, currentPrice);
    }

    /// @notice 执行看涨期权
    function _executeCallOption(IMorpho.MarketParams memory marketParams, address user, uint256 currentPrice)
        internal
    {
        bytes32 marketId = _getMarketId(marketParams);
        CollarParams storage collar = userCollars[user][marketId];

        // 计算执行损失
        uint256 strikePrice = collar.callStrikePrice;
        uint256 executionValue = (currentPrice - strikePrice) * WAD / currentPrice;

        // 执行看涨期权限制
        _executeProtection(marketParams, user, executionValue, false);

        emit CollarExecuted(user, marketId, false, executionValue, currentPrice);
    }

    /// @notice 执行保护机制
    function _executeProtection(
        IMorpho.MarketParams memory marketParams,
        address user,
        uint256 executionValue,
        bool isPut
    ) internal {
        if (isPut) {
            // 看跌期权执行：增加抵押品或减少借款
            // 可以通过闪电贷来快速调整仓位
            _adjustPositionForProtection(marketParams, user, executionValue, true);
        } else {
            // 看涨期权执行：减少抵押品或增加借款
            _adjustPositionForProtection(marketParams, user, executionValue, false);
        }
    }

    /// @notice 调整仓位以应对期权执行
    function _adjustPositionForProtection(
        IMorpho.MarketParams memory marketParams,
        address user,
        uint256 adjustmentValue,
        bool isProtection
    ) internal {
        // 使用闪电贷来快速调整仓位
        uint256 flashLoanAmount = adjustmentValue;

        morpho.flashLoan(
            marketParams.loanToken,
            flashLoanAmount,
            abi.encode(this._flashLoanCallback.selector, marketParams, user, adjustmentValue, isProtection)
        );
    }

    /// @notice 闪电贷回调
    function _flashLoanCallback(
        IMorpho.MarketParams memory marketParams,
        address user,
        uint256 adjustmentValue,
        bool isProtection
    ) external {
        require(msg.sender == address(morpho), "Unauthorized");

        if (isProtection) {
            // 保护模式：增加抵押品或减少借款
            // 使用闪电贷资金来偿还部分借款
            morpho.repay(marketParams, adjustmentValue, 0, user, "");
        } else {
            // 限制模式：减少抵押品或增加借款
            // 使用闪电贷资金来增加借款
            morpho.borrow(marketParams, adjustmentValue, 0, user, address(this));
        }
    }

    /// @notice 处理清算回调
    function _handleLiquidationCallback(uint256 repaidAssets, bytes calldata data) internal {
        // 解析清算数据
        (IMorpho.MarketParams memory marketParams, address borrower) = abi.decode(data, (IMorpho.MarketParams, address));

        // 检查是否有活跃的领口策略
        bytes32 marketId = _getMarketId(marketParams);
        CollarParams storage collar = userCollars[borrower][marketId];

        if (collar.isActive) {
            // 自动执行看跌期权保护剩余抵押品
            uint256 currentPrice = IOracle(marketParams.oracle).price();
            if (currentPrice < collar.putStrikePrice) {
                _executePutOption(marketParams, borrower, currentPrice);
            }
        }
    }

    /// @notice 供应抵押品并触发回调
    function _supplyCollateralWithCallback(IMorpho.MarketParams memory marketParams, uint256 collateralAmount)
        internal
    {
        // 编码回调数据
        bytes memory callbackData = abi.encode(this.onMorphoSupplyCollateral.selector, collateralAmount);

        morpho.supplyCollateral(marketParams, collateralAmount, msg.sender, callbackData);
    }

    /// @notice 提取抵押品
    function _withdrawCollateral(IMorpho.MarketParams memory marketParams) internal {
        // 获取用户抵押品余额
        bytes32 marketId = _getMarketId(marketParams);
        (,, uint256 collateral) = morpho.position(marketId, msg.sender);

        if (collateral > 0) {
            morpho.withdrawCollateral(marketParams, collateral, msg.sender, msg.sender);
        }
    }

    /// @notice 关闭期权头寸
    function _closeOptionPositions(address collateralToken) internal {
        // 这里需要与期权交易所交互来平仓
        // 简化实现：直接转移代币
    }

    /// @notice 获取市场ID
    function _getMarketId(IMorpho.MarketParams memory marketParams) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                marketParams.loanToken,
                marketParams.collateralToken,
                marketParams.oracle,
                marketParams.irm,
                marketParams.lltv
            )
        );
    }

    // ============ 管理函数 ============

    /// @notice 设置期权交易所地址
    function setOptionExchange(address _optionExchange) external {
        require(msg.sender == owner, "Unauthorized");
        optionExchange = _optionExchange;
    }

    /// @notice 提取合约中的代币
    function withdrawToken(address token, uint256 amount) external {
        require(msg.sender == owner, "Unauthorized");
        IERC20(token).transfer(owner, amount);
    }
}
