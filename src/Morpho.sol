// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {
    Id,
    IMorphoStaticTyping,
    IMorphoBase,
    MarketParams,
    Position,
    Market,
    Authorization,
    Signature
} from "./interfaces/IMorpho.sol";
import {
    IMorphoLiquidateCallback,
    IMorphoRepayCallback,
    IMorphoSupplyCallback,
    IMorphoSupplyCollateralCallback,
    IMorphoFlashLoanCallback
} from "./interfaces/IMorphoCallbacks.sol";
import {IIrm} from "./interfaces/IIrm.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IOracle} from "./interfaces/IOracle.sol";

import "./libraries/ConstantsLib.sol";
import {UtilsLib} from "./libraries/UtilsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {MathLib, WAD} from "./libraries/MathLib.sol";
import {SharesMathLib} from "./libraries/SharesMathLib.sol";
import {MarketParamsLib} from "./libraries/MarketParamsLib.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";

/// @title Morpho
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice The Morpho contract.
contract Morpho is IMorphoStaticTyping {
    using MathLib for uint128;
    using MathLib for uint256;
    using UtilsLib for uint256;
    using SharesMathLib for uint256;
    using SafeTransferLib for IERC20;
    using MarketParamsLib for MarketParams;

    /* IMMUTABLES */

    /// @inheritdoc IMorphoBase
    bytes32 public immutable DOMAIN_SEPARATOR;

    /* STORAGE */

    /// @inheritdoc IMorphoBase
    address public owner;
    /// @inheritdoc IMorphoBase
    address public feeRecipient;
    /// @inheritdoc IMorphoStaticTyping
    mapping(Id => mapping(address => Position)) public position;
    /// @inheritdoc IMorphoStaticTyping
    mapping(Id => Market) public market;
    /// @inheritdoc IMorphoBase
    mapping(address => bool) public isIrmEnabled;
    /// @inheritdoc IMorphoBase
    mapping(uint256 => bool) public isLltvEnabled;
    /// @inheritdoc IMorphoBase
    mapping(address => mapping(address => bool)) public isAuthorized;
    /// @inheritdoc IMorphoBase
    mapping(address => uint256) public nonce;
    /// @inheritdoc IMorphoStaticTyping
    mapping(Id => MarketParams) public idToMarketParams;

    /* CONSTRUCTOR */

    /// @param newOwner The new owner of the contract.
    constructor(address newOwner) {
        require(newOwner != address(0), ErrorsLib.ZERO_ADDRESS);

        DOMAIN_SEPARATOR = keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(this)));
        owner = newOwner;

        emit EventsLib.SetOwner(newOwner);
    }

    /* MODIFIERS */

    /// @dev Reverts if the caller is not the owner.
    modifier onlyOwner() {
        require(msg.sender == owner, ErrorsLib.NOT_OWNER);
        _;
    }

    /* ONLY OWNER FUNCTIONS */

    /// @inheritdoc IMorphoBase
    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != owner, ErrorsLib.ALREADY_SET);

        owner = newOwner;

        emit EventsLib.SetOwner(newOwner);
    }

    /// @inheritdoc IMorphoBase
    function enableIrm(address irm) external onlyOwner {
        require(!isIrmEnabled[irm], ErrorsLib.ALREADY_SET);

        isIrmEnabled[irm] = true;

        emit EventsLib.EnableIrm(irm);
    }

    /// @inheritdoc IMorphoBase
    function enableLltv(uint256 lltv) external onlyOwner {
        require(!isLltvEnabled[lltv], ErrorsLib.ALREADY_SET);
        require(lltv < WAD, ErrorsLib.MAX_LLTV_EXCEEDED);

        isLltvEnabled[lltv] = true;

        emit EventsLib.EnableLltv(lltv);
    }

    /// @inheritdoc IMorphoBase
    function setFee(MarketParams memory marketParams, uint256 newFee) external onlyOwner {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(newFee != market[id].fee, ErrorsLib.ALREADY_SET);
        require(newFee <= MAX_FEE, ErrorsLib.MAX_FEE_EXCEEDED);

        // Accrue interest using the previous fee set before changing it.
        _accrueInterest(marketParams, id);

        // Safe "unchecked" cast.
        market[id].fee = uint128(newFee);

        emit EventsLib.SetFee(id, newFee);
    }

    /// @inheritdoc IMorphoBase
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        require(newFeeRecipient != feeRecipient, ErrorsLib.ALREADY_SET);

        feeRecipient = newFeeRecipient;

        emit EventsLib.SetFeeRecipient(newFeeRecipient);
    }

    /* MARKET CREATION */

    /// @inheritdoc IMorphoBase
    function createMarket(MarketParams memory marketParams) external {
        Id id = marketParams.id();
        require(isIrmEnabled[marketParams.irm], ErrorsLib.IRM_NOT_ENABLED);
        require(isLltvEnabled[marketParams.lltv], ErrorsLib.LLTV_NOT_ENABLED);
        require(market[id].lastUpdate == 0, ErrorsLib.MARKET_ALREADY_CREATED);

        // Safe "unchecked" cast.
        market[id].lastUpdate = uint128(block.timestamp);
        idToMarketParams[id] = marketParams;

        /**
         * 记录到区块链日志：将事件数据写入区块链的事件日志中
         *     供外部监听：前端应用、监控服务等可以监听这些事件
         *     不执行任何函数：事件只是数据记录，不会调用任何代码
         *     1. 前端应用监听
         *     // 监听 CreateMarket 事件
         *     const filter = morphoContract.filters.CreateMarket();
         *     morphoContract.on(filter, (id, marketParams, event) => {
         *         console.log('New market created:', id, marketParams);
         *         // 更新 UI，刷新市场列表等
         *     });
         *     2. 后端服务索引
         *     // 事件索引服务
         *     const events = await morphoContract.queryFilter('CreateMarket', fromBlock, toBlock);
         *     events.forEach(event => {
         *         // 将事件数据存储到数据库
         *         saveMarketToDatabase(event.args.id, event.args.marketParams);
         *     });
         *     3. 链上其他合约
         *     其他合约可以通过日志查询来获取历史事件，但不能直接"监听"事件。
         *
         *     4. 主动查询
         *     4.1 直接查询事件日志
         *     // 使用 ethers.js 查询历史事件
         *     const morphoContract = new ethers.Contract(address, abi, provider);
         *
         *     // 查询所有 CreateMarket 事件
         *     const events = await morphoContract.queryFilter('CreateMarket');
         *
         *     // 查询指定区块范围的事件
         *     const events = await morphoContract.queryFilter('CreateMarket', fromBlock, toBlock);
         *
         *     // 查询特定市场ID的事件
         *     const filter = morphoContract.filters.CreateMarket(marketId);
         *     const events = await morphoContract.queryFilter(filter);
         *
         *     4.2. 使用 Web3.js
         *     // 获取过去的事件
         *     const events = await web3.eth.getPastLogs({
         *         address: morphoAddress,
         *         topics: [
         *             web3.utils.keccak256('CreateMarket(bytes32,MarketParams)')
         *         ],
         *         fromBlock: 0,
         *         toBlock: 'latest'
         *     });
         *     4.3. 通过区块浏览器
         *     在 Etherscan 等区块浏览器上：
         *
         *     进入合约地址页面
         *     点击 "Events" 标签
         *     可以看到所有历史事件，包括 CreateMarket
         *     4.4 直接查询合约状态
         *     // 通过合约的状态变量查询
         *     mapping(Id => Market) public market;
         *     mapping(Id => MarketParams) public idToMarketParams;
         *
         *     // 如果 market[id].lastUpdate > 0，说明市场已创建
         *     // 通过 idToMarketParams[id] 可以获取市场参数
         *     4.5. 使用 The Graph 等索引服务
         *     如果项目部署了 Graph Protocol 子图，可以通过 GraphQL 查询：
         *     query {
         *         markets(where: { id: "0x..." }) {
         *             id
         *             marketParams {
         *                 loanToken
         *                 collateralToken
         *                 irm
         *                 oracle
         *                 lltv
         *             }
         *         }
         */
        emit EventsLib.CreateMarket(id, marketParams);

        // Call to initialize the IRM in case it is stateful.
        if (marketParams.irm != address(0)) IIrm(marketParams.irm).borrowRate(marketParams, market[id]);
    }

    /* SUPPLY MANAGEMENT */

    /// @inheritdoc IMorphoBase
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
        require(onBehalf != address(0), ErrorsLib.ZERO_ADDRESS);

        _accrueInterest(marketParams, id);

        if (assets > 0) shares = assets.toSharesDown(market[id].totalSupplyAssets, market[id].totalSupplyShares);
        else assets = shares.toAssetsUp(market[id].totalSupplyAssets, market[id].totalSupplyShares);

        position[id][onBehalf].supplyShares += shares;
        market[id].totalSupplyShares += shares.toUint128();
        market[id].totalSupplyAssets += assets.toUint128();

        emit EventsLib.Supply(id, msg.sender, onBehalf, assets, shares);

        if (data.length > 0) IMorphoSupplyCallback(msg.sender).onMorphoSupply(assets, data);

        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        return (assets, shares);
    }

    /// @inheritdoc IMorphoBase
    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        // No need to verify that onBehalf != address(0) thanks to the following authorization check.
        require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);

        _accrueInterest(marketParams, id);

        if (assets > 0) shares = assets.toSharesUp(market[id].totalSupplyAssets, market[id].totalSupplyShares);
        else assets = shares.toAssetsDown(market[id].totalSupplyAssets, market[id].totalSupplyShares);

        position[id][onBehalf].supplyShares -= shares;
        market[id].totalSupplyShares -= shares.toUint128();
        market[id].totalSupplyAssets -= assets.toUint128();

        require(market[id].totalBorrowAssets <= market[id].totalSupplyAssets, ErrorsLib.INSUFFICIENT_LIQUIDITY);

        emit EventsLib.Withdraw(id, msg.sender, onBehalf, receiver, assets, shares);

        IERC20(marketParams.loanToken).safeTransfer(receiver, assets);

        return (assets, shares);
    }

    /* BORROW MANAGEMENT */

    /// @inheritdoc IMorphoBase
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        // No need to verify that onBehalf != address(0) thanks to the following authorization check.
        require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);

        _accrueInterest(marketParams, id);

        if (assets > 0) shares = assets.toSharesUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);
        else assets = shares.toAssetsDown(market[id].totalBorrowAssets, market[id].totalBorrowShares);

        position[id][onBehalf].borrowShares += shares.toUint128();
        market[id].totalBorrowShares += shares.toUint128();
        market[id].totalBorrowAssets += assets.toUint128();

        require(_isHealthy(marketParams, id, onBehalf), ErrorsLib.INSUFFICIENT_COLLATERAL);
        require(market[id].totalBorrowAssets <= market[id].totalSupplyAssets, ErrorsLib.INSUFFICIENT_LIQUIDITY);

        emit EventsLib.Borrow(id, msg.sender, onBehalf, receiver, assets, shares);

        IERC20(marketParams.loanToken).safeTransfer(receiver, assets);

        return (assets, shares);
    }

    /// @inheritdoc IMorphoBase
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
        require(onBehalf != address(0), ErrorsLib.ZERO_ADDRESS);

        _accrueInterest(marketParams, id);

        if (assets > 0) shares = assets.toSharesDown(market[id].totalBorrowAssets, market[id].totalBorrowShares);
        else assets = shares.toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);

        position[id][onBehalf].borrowShares -= shares.toUint128();
        market[id].totalBorrowShares -= shares.toUint128();
        market[id].totalBorrowAssets = UtilsLib.zeroFloorSub(market[id].totalBorrowAssets, assets).toUint128();

        // `assets` may be greater than `totalBorrowAssets` by 1.
        emit EventsLib.Repay(id, msg.sender, onBehalf, assets, shares);

        if (data.length > 0) IMorphoRepayCallback(msg.sender).onMorphoRepay(assets, data);

        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        return (assets, shares);
    }

    /* COLLATERAL MANAGEMENT */

    /// @inheritdoc IMorphoBase
    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes calldata data)
        external
    {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(assets != 0, ErrorsLib.ZERO_ASSETS);
        require(onBehalf != address(0), ErrorsLib.ZERO_ADDRESS);

        // Don't accrue interest because it's not required and it saves gas.

        position[id][onBehalf].collateral += assets.toUint128();

        emit EventsLib.SupplyCollateral(id, msg.sender, onBehalf, assets);

        if (data.length > 0) IMorphoSupplyCollateralCallback(msg.sender).onMorphoSupplyCollateral(assets, data);

        IERC20(marketParams.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    /// @inheritdoc IMorphoBase
    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external
    {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(assets != 0, ErrorsLib.ZERO_ASSETS);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        // No need to verify that onBehalf != address(0) thanks to the following authorization check.
        require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);

        _accrueInterest(marketParams, id);

        position[id][onBehalf].collateral -= assets.toUint128();

        require(_isHealthy(marketParams, id, onBehalf), ErrorsLib.INSUFFICIENT_COLLATERAL);

        emit EventsLib.WithdrawCollateral(id, msg.sender, onBehalf, receiver, assets);

        IERC20(marketParams.collateralToken).safeTransfer(receiver, assets);
    }

    /* LIQUIDATION */

    /// @inheritdoc IMorphoBase
    function liquidate(
        MarketParams memory marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata data
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(seizedAssets, repaidShares), ErrorsLib.INCONSISTENT_INPUT);

        _accrueInterest(marketParams, id);

        {
            uint256 collateralPrice = IOracle(marketParams.oracle).price();

            require(!_isHealthy(marketParams, id, borrower, collateralPrice), ErrorsLib.HEALTHY_POSITION);

            // The liquidation incentive factor is min(maxLiquidationIncentiveFactor, 1/(1 - cursor*(1 - lltv))).
            uint256 liquidationIncentiveFactor = UtilsLib.min(
                MAX_LIQUIDATION_INCENTIVE_FACTOR,
                WAD.wDivDown(WAD - LIQUIDATION_CURSOR.wMulDown(WAD - marketParams.lltv))
            );

            if (seizedAssets > 0) {
                uint256 seizedAssetsQuoted = seizedAssets.mulDivUp(collateralPrice, ORACLE_PRICE_SCALE);

                repaidShares = seizedAssetsQuoted.wDivUp(liquidationIncentiveFactor).toSharesUp(
                    market[id].totalBorrowAssets, market[id].totalBorrowShares
                );
            } else {
                seizedAssets = repaidShares.toAssetsDown(market[id].totalBorrowAssets, market[id].totalBorrowShares)
                    .wMulDown(liquidationIncentiveFactor).mulDivDown(ORACLE_PRICE_SCALE, collateralPrice);
            }
        }
        uint256 repaidAssets = repaidShares.toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);

        position[id][borrower].borrowShares -= repaidShares.toUint128();
        market[id].totalBorrowShares -= repaidShares.toUint128();
        market[id].totalBorrowAssets = UtilsLib.zeroFloorSub(market[id].totalBorrowAssets, repaidAssets).toUint128();

        position[id][borrower].collateral -= seizedAssets.toUint128();

        uint256 badDebtShares;
        uint256 badDebtAssets;
        if (position[id][borrower].collateral == 0) {
            badDebtShares = position[id][borrower].borrowShares;
            badDebtAssets = UtilsLib.min(
                market[id].totalBorrowAssets,
                badDebtShares.toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares)
            );

            market[id].totalBorrowAssets -= badDebtAssets.toUint128();
            market[id].totalSupplyAssets -= badDebtAssets.toUint128();
            market[id].totalBorrowShares -= badDebtShares.toUint128();
            position[id][borrower].borrowShares = 0;
        }

        // `repaidAssets` may be greater than `totalBorrowAssets` by 1.
        emit EventsLib.Liquidate(
            id, msg.sender, borrower, repaidAssets, repaidShares, seizedAssets, badDebtAssets, badDebtShares
        );

        IERC20(marketParams.collateralToken).safeTransfer(msg.sender, seizedAssets);

        if (data.length > 0) IMorphoLiquidateCallback(msg.sender).onMorphoLiquidate(repaidAssets, data);

        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), repaidAssets);

        return (seizedAssets, repaidAssets);
    }

    /* FLASH LOANS */

    /// @inheritdoc IMorphoBase
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        require(assets != 0, ErrorsLib.ZERO_ASSETS);

        emit EventsLib.FlashLoan(msg.sender, token, assets);

        IERC20(token).safeTransfer(msg.sender, assets);

        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);

        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
    }

    /* AUTHORIZATION */

    /// @inheritdoc IMorphoBase
    function setAuthorization(address authorized, bool newIsAuthorized) external {
        require(newIsAuthorized != isAuthorized[msg.sender][authorized], ErrorsLib.ALREADY_SET);

        isAuthorized[msg.sender][authorized] = newIsAuthorized;

        emit EventsLib.SetAuthorization(msg.sender, msg.sender, authorized, newIsAuthorized);
    }

    /// @inheritdoc IMorphoBase
    function setAuthorizationWithSig(Authorization memory authorization, Signature calldata signature) external {
        /// Do not check whether authorization is already set because the nonce increment is a desired side effect.
        require(block.timestamp <= authorization.deadline, ErrorsLib.SIGNATURE_EXPIRED);
        require(authorization.nonce == nonce[authorization.authorizer]++, ErrorsLib.INVALID_NONCE);

        bytes32 hashStruct = keccak256(abi.encode(AUTHORIZATION_TYPEHASH, authorization));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", DOMAIN_SEPARATOR, hashStruct));
        address signatory = ecrecover(digest, signature.v, signature.r, signature.s);

        require(signatory != address(0) && authorization.authorizer == signatory, ErrorsLib.INVALID_SIGNATURE);

        emit EventsLib.IncrementNonce(msg.sender, authorization.authorizer, authorization.nonce);

        isAuthorized[authorization.authorizer][authorization.authorized] = authorization.isAuthorized;

        emit EventsLib.SetAuthorization(
            msg.sender, authorization.authorizer, authorization.authorized, authorization.isAuthorized
        );
    }

    /// @dev Returns whether the sender is authorized to manage `onBehalf`'s positions.
    function _isSenderAuthorized(address onBehalf) internal view returns (bool) {
        return msg.sender == onBehalf || isAuthorized[onBehalf][msg.sender];
    }

    /* INTEREST MANAGEMENT */

    /// @inheritdoc IMorphoBase
    function accrueInterest(MarketParams memory marketParams) external {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);

        _accrueInterest(marketParams, id);
    }

    /// @dev Accrues interest for the given market `marketParams`.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    function _accrueInterest(MarketParams memory marketParams, Id id) internal {
        // 计算自上次利息更新以来的时间差（秒）
        uint256 elapsed = block.timestamp - market[id].lastUpdate;
        if (elapsed == 0) return; // 如果时间差为0，则不计算利息

        if (marketParams.irm != address(0)) {
            // 从IRM利率模型获取当前借款利率（基于市场参数和状态）
            uint256 borrowRate = IIrm(marketParams.irm).borrowRate(marketParams, market[id]);
            // 计算应计利息：总借款 × 利率 × 时间因子（泰勒展开近似复利）
            uint256 interest = market[id].totalBorrowAssets.wMulDown(borrowRate.wTaylorCompounded(elapsed));
            // 更新总借款资产和总供应资产
            market[id].totalBorrowAssets += interest.toUint128();
            market[id].totalSupplyAssets += interest.toUint128();

            // 手续费处理逻辑（若手续费率非零）
            uint256 feeShares;
            if (market[id].fee != 0) {
                // 计算手续费金额（利息 × 手续费率）
                uint256 feeAmount = interest.wMulDown(market[id].fee);

                /* 
                * 计算手续费对应的份额：
                * 公式：feeShares = feeAmount / (totalSupplyAssets - feeAmount) * totalSupplyShares
                * 注：分母减feeAmount是为了补偿totalSupplyAssets已包含全额利息的会计处理
                */
                // The fee amount is subtracted from the total supply in this calculation to compensate for the fact
                // that total supply is already increased by the full interest (including the fee amount).
                feeShares =
                    feeAmount.toSharesDown(market[id].totalSupplyAssets - feeAmount, market[id].totalSupplyShares);

                // 分配给手续费接收方并更新总份额
                position[id][feeRecipient].supplyShares += feeShares;
                market[id].totalSupplyShares += feeShares.toUint128();
            }

            // 触发利息累积事件（便于链下监控）
            emit EventsLib.AccrueInterest(id, borrowRate, interest, feeShares);
        }

        // Safe "unchecked" cast.
        // 安全更新最后更新时间戳（unchecked节省Gas，实际场景不会溢出）
        market[id].lastUpdate = uint128(block.timestamp);
    }

    /* HEALTH CHECK */

    /// @dev Returns whether the position of `borrower` in the given market `marketParams` is healthy.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    function _isHealthy(MarketParams memory marketParams, Id id, address borrower) internal view returns (bool) {
        if (position[id][borrower].borrowShares == 0) return true;

        uint256 collateralPrice = IOracle(marketParams.oracle).price();

        return _isHealthy(marketParams, id, borrower, collateralPrice);
    }

    /// @dev Returns whether the position of `borrower` in the given market `marketParams` with the given
    /// `collateralPrice` is healthy.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    /// @dev Rounds in favor of the protocol, so one might not be able to borrow exactly `maxBorrow` but one unit less.
    function _isHealthy(MarketParams memory marketParams, Id id, address borrower, uint256 collateralPrice)
        internal
        view
        returns (bool)
    {
        uint256 borrowed = uint256(position[id][borrower].borrowShares).toAssetsUp(
            market[id].totalBorrowAssets, market[id].totalBorrowShares
        );
        uint256 maxBorrow = uint256(position[id][borrower].collateral).mulDivDown(collateralPrice, ORACLE_PRICE_SCALE)
            .wMulDown(marketParams.lltv);

        return maxBorrow >= borrowed;
    }

    /* STORAGE VIEW */

    /// @inheritdoc IMorphoBase
    function extSloads(bytes32[] calldata slots) external view returns (bytes32[] memory res) {
        uint256 nSlots = slots.length;

        res = new bytes32[](nSlots);

        for (uint256 i; i < nSlots;) {
            bytes32 slot = slots[i++];

            assembly ("memory-safe") {
                mstore(add(res, mul(i, 32)), sload(slot))
            }
        }
    }
}
