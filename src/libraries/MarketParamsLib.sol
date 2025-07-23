// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Id, MarketParams} from "../interfaces/IMorpho.sol";

/// @title MarketParamsLib
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice Library to convert a market to its id.
library MarketParamsLib {
    /// @notice The length of the data used to compute the id of a market.
    /// @dev The length is 5 * 32 because `MarketParams` has 5 variables of 32 bytes each.
    uint256 internal constant MARKET_PARAMS_BYTES_LENGTH = 5 * 32;

    /// @notice Returns the id of the market `marketParams`.
    function id(MarketParams memory marketParams) internal pure returns (Id marketParamsId) {
        // 内联汇编块：使用 memory-safe 标记确保内存操作的安全性
        assembly ("memory-safe") {
            /* 
             * 设计逻辑：
             * 1. 将 marketParams 视为连续内存块，包含 5 个 32 字节字段
             * 2. keccak256 哈希算法保证相同输入生成相同 ID，不同输入几乎不会碰撞，
             * 3. 此 ID 用于在 Morpho 协议中唯一标识一个借贷市场
             */
            marketParamsId := keccak256(marketParams, MARKET_PARAMS_BYTES_LENGTH)
        }
    }
}
