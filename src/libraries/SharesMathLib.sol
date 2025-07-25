// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {MathLib} from "./MathLib.sol";

/// @title SharesMathLib
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice Shares management library.
/// @dev This implementation mitigates share price manipulations, using OpenZeppelin's method of virtual shares:
/// https://docs.openzeppelin.com/contracts/4.x/erc4626#inflation-attack.
library SharesMathLib {
    // 将 MathLib 库中的函数附加到 uint256 类型上，使得 uint256 类型的变量可以直接调用这些库函数。
    using MathLib for uint256;

    // 防止早期“薅羊毛”或“份额操纵”问题。这会导致“首存攻击”，严重影响公平性。
    /**
     * 天才设计：
     *     假设市场刚创建，totalAssets = 0, totalShares = 0：
     *     用户A存入100 USDC：
     *     shares = 100 * (0 + 1e6) / (0 + 1) = 100 * 1e6 / 1 = 100,000,000 shares
     *     用户B再存入100 USDC：
     *     shares = 100 * (100 + 1)e6 / (100 + 1) = 100 * 100,001,000 / 101 = 99,010,000 shares
     *     这样，每个人的份额都和实际贡献成比例，不会被首存者薅羊毛。
     */

    /// @dev The number of virtual shares has been chosen low enough to prevent overflows, and high enough to ensure
    /// high precision computations.
    /// @dev Virtual shares can never be redeemed for the assets they are entitled to, but it is assumed the share price
    /// stays low enough not to inflate these assets to a significant value.
    /// @dev Warning: The assets to which virtual borrow shares are entitled behave like unrealizable bad debt.
    uint256 internal constant VIRTUAL_SHARES = 1e6;

    /// @dev A number of virtual assets of 1 enforces a conversion rate between shares and assets when a market is
    /// empty.
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @dev Calculates the value of `assets` quoted in shares, rounding down.
    /// @dev retuns assets * (totalShares + VIRTUAL_SHARES) / (totalAssets + VIRTUAL_ASSETS)
    function toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return assets.mulDivDown(totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    /// @dev Calculates the value of `shares` quoted in assets, rounding down.
    /// @dev retuns shares * (totalAssets + VIRTUAL_ASSETS) / (totalShares + VIRTUAL_SHARES)
    function toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return shares.mulDivDown(totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    /// @dev Calculates the value of `assets` quoted in shares, rounding up.
    /// @dev retuns assets * (totalShares + VIRTUAL_SHARES) / (totalAssets + VIRTUAL_ASSETS)
    function toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return assets.mulDivUp(totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    /// @dev Calculates the value of `shares` quoted in assets, rounding up.
    /// @dev retuns shares * (totalAssets + VIRTUAL_ASSETS) / (totalShares + VIRTUAL_SHARES)
    function toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return shares.mulDivUp(totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }
}
