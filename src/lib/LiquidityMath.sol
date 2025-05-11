// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "prb-math/PRBMath.sol"; // 高精度乘除法库
import "./FixedPoint96.sol"; // 定义 Q96 = 2^96，用于定点运算

library LiquidityMath {
    /// @notice 根据 amount0 计算在 [sqrtPriceAX96, sqrtPriceBX96] 区间内可获得的流动性 L
    /// @param sqrtPriceAX96 区间下限的 √价格，Q96 定点
    /// @param sqrtPriceBX96 区间上限的 √价格，Q96 定点
    /// @param amount0 代币0 的数量
    /// @return liquidity 计算得到的流动性，uint128 表示
    function getLiquidityForAmount0(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount0)
        internal
        pure
        returns (uint128 liquidity)
    {
        // 保证 sqrtPriceAX96 ≤ sqrtPriceBX96
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        // intermediate = (sqrtPriceA * sqrtPriceB) / Q96，向下取整
        uint256 intermediate = PRBMath.mulDiv(sqrtPriceAX96, sqrtPriceBX96, FixedPoint96.Q96);

        // liquidity = amount0 * intermediate / (sqrtPriceB - sqrtPriceA)，向下取整
        liquidity = uint128(PRBMath.mulDiv(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96));
    }

    /// @notice 根据 amount1 计算在 [sqrtPriceAX96, sqrtPriceBX96] 区间内可获得的流动性 L
    /// @param sqrtPriceAX96 区间下限的 √价格，Q96 定点
    /// @param sqrtPriceBX96 区间上限的 √价格，Q96 定点
    /// @param amount1 代币1 的数量
    /// @return liquidity 计算得到的流动性，uint128 表示
    function getLiquidityForAmount1(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
        internal
        pure
        returns (uint128 liquidity)
    {
        // 保证 sqrtPriceAX96 ≤ sqrtPriceBX96
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        // liquidity = amount1 * Q96 / (sqrtPriceB - sqrtPriceA)，向下取整
        liquidity = uint128(PRBMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceBX96 - sqrtPriceAX96));
    }

    /// @notice 根据 amount0 和 amount1，及当前价格计算最大可提供的流动性
    /// @param sqrtPriceX96     当前价格的 √ 值，Q96 定点
    /// @param sqrtPriceAX96    区间下限的 √价格，Q96 定点
    /// @param sqrtPriceBX96    区间上限的 √价格，Q96 定点
    /// @param amount0          可提供的代币0 数量
    /// @param amount1          可提供的代币1 数量
    /// @return liquidity       能同时满足 amount0/amount1 的最大流动性
    function getLiquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        // 保证 sqrtPriceAX96 ≤ sqrtPriceBX96
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        // 如果当前价格在区间左侧：全部用 amount0 提供流动性
        if (sqrtPriceX96 <= sqrtPriceAX96) {
            liquidity = getLiquidityForAmount0(sqrtPriceAX96, sqrtPriceBX96, amount0);
        }
        // 如果当前价格在区间中间：需要同时用 amount0 和 amount1，取最小可行值
        else if (sqrtPriceX96 <= sqrtPriceBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(sqrtPriceAX96, sqrtPriceBX96, amount0);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, amount1);
            // 取两者中较小的值，保证两种代币都足够
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        }
        // 如果当前价格在区间右侧：全部用 amount1 提供流动性
        else {
            liquidity = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, amount1);
        }
    }

    /// @notice 在 signed int128 y 的基础上，对 unsigned x 做加/减运算
    /// @param x 原始流动性，uint128
    /// @param y 流动性增量，可正可负
    /// @return z 计算后的新流动性，uint128
    function addLiquidity(uint128 x, int128 y) internal pure returns (uint128 z) {
        // 如果 y < 0，则减去流动性
        if (y < 0) {
            return x - uint128(-y);
        } else {
            // 否则，增加流动性
            return x + uint128(y);
        }
    }
}
