// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.14;

import "./Math.sol";
import "./LiquidityMath.sol";

library Tick {
    struct Info {
        bool initialized;
        uint128 liquidityGross;
        // 记录的是当价格从下方穿过某个 tick 时，池子总流动性的净变化
        int128 liquidityNet;
        // 低于现价tick累积的费用
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
    }

    function update(
        mapping(int24 => Tick.Info) storage self,
        // tick 代表边界tick
        int24 tick,
        int24 currentTick,
        int128 liquidityDelta,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        // 布尔值upper表示是否是上界
        bool upper
    ) internal returns (bool flipped) {
        Tick.Info storage tickInfo = self[tick];
        uint128 liquidityBefore = tickInfo.liquidityGross;
        uint128 liquidityAfter = LiquidityMath.addLiquidity(liquidityBefore, liquidityDelta);
        // 只关心tick是否有流动性，如果都有流动性，说明该tick已经翻转，flipped为false
        flipped = (liquidityAfter == 0) != (liquidityBefore == 0);

        if (liquidityBefore == 0) {
            if (tick <= currentTick) {
                tickInfo.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                tickInfo.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
            }

            tickInfo.initialized = true;
        }

        tickInfo.liquidityGross = liquidityAfter;
        //如果 upper = true（上界）：liquidityNet 减去 liquidityDelta。
        //如果 upper = false（下界）：liquidityNet 加上 liquidityDelta。
        tickInfo.liquidityNet = upper
            ? int128(int256(tickInfo.liquidityNet) - liquidityDelta)
            : int128(int256(tickInfo.liquidityNet) + liquidityDelta);
    }

    function cross(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal returns (int128 liquidityDelta) {
        Tick.Info storage info = self[tick];
        info.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - info.feeGrowthOutside0X128;
        info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - info.feeGrowthOutside1X128;

        liquidityDelta = info.liquidityNet;
    }

    // 对于上界还是下界的定义是根据头寸自己选择提供流动性区间来决定的，是各自独立的，跟用户选择有关系
    function getFeeGrowthInside(
        mapping(int24 => Tick.Info) storage self,
        int24 lowerTick_,
        int24 upperTick_,
        int24 currentTick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        Tick.Info storage lowerTick = self[lowerTick_];
        Tick.Info storage upperTick = self[upperTick_];

        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;
        if (currentTick >= lowerTick_) {
            feeGrowthBelow0X128 = lowerTick.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = lowerTick.feeGrowthOutside1X128;
        } else {
            feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lowerTick.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lowerTick.feeGrowthOutside1X128;
        }

        uint256 feeGrowthAbove0X128;
        uint256 feeGrowthAbove1X128;
        if (currentTick < upperTick_) {
            feeGrowthAbove0X128 = upperTick.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = upperTick.feeGrowthOutside1X128;
        } else {
            feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upperTick.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upperTick.feeGrowthOutside1X128;
        }

        feeGrowthInside0X128 = feeGrowthGlobal0X128 - upperTick.feeGrowthOutside0X128 - lowerTick.feeGrowthOutside0X128;
        feeGrowthInside1X128 = feeGrowthGlobal1X128 - upperTick.feeGrowthOutside1X128 - lowerTick.feeGrowthOutside1X128;
    }
}
