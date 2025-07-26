// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title IVolcubeCallbacks
/// @author Volcube Labs
/// @notice Interface for Volcube callback functions
interface IVolcubeCallbacks {
    /// @notice Callback function called after a collar protection is created
    /// @param assets The amount of assets supplied as collateral
    /// @param data Arbitrary data passed to the callback
    function onVolcubeCollarCreated(uint256 assets, bytes calldata data) external;

    /// @notice Callback function called when put option protection is triggered
    /// @param protectionAmount The amount of protection received
    /// @param data Arbitrary data passed to the callback
    function onVolcubePutTriggered(uint256 protectionAmount, bytes calldata data) external;

    /// @notice Callback function called when call option is exercised
    /// @param collateralSold The amount of collateral sold
    /// @param usdcReceived The amount of USDC received
    /// @param data Arbitrary data passed to the callback
    function onVolcubeCallExercised(uint256 collateralSold, uint256 usdcReceived, bytes calldata data) external;

    /// @notice Callback function called after supply
    /// @param assets The amount of assets supplied
    /// @param data Arbitrary data passed to the callback
    function onVolcubeSupply(uint256 assets, bytes calldata data) external;

    /// @notice Callback function called after repay
    /// @param assets The amount of assets repaid
    /// @param data Arbitrary data passed to the callback
    function onVolcubeRepay(uint256 assets, bytes calldata data) external;

    /// @notice Callback function called after supply collateral
    /// @param assets The amount of collateral supplied
    /// @param data Arbitrary data passed to the callback
    function onVolcubeSupplyCollateral(uint256 assets, bytes calldata data) external;

    /// @notice Callback function called after liquidate
    /// @param repaidAssets The amount of assets repaid
    /// @param data Arbitrary data passed to the callback
    function onVolcubeLiquidate(uint256 repaidAssets, bytes calldata data) external;

    /// @notice Callback function called after flash loan
    /// @param assets The amount of assets flash loaned
    /// @param data Arbitrary data passed to the callback
    function onVolcubeFlashLoan(uint256 assets, bytes calldata data) external;
}
