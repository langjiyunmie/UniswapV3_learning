// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "./Math.sol";

library SwapMath {
    function computeSwapStep(
        uint160 sqrtPriceCurrentX96,
        uint160 sqrtPriceTargetX96,
        uint128 liquidity,
        uint256 amountRemaining,
        uint24 fee
    ) internal pure returns (uint160 sqrtPriceNextX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount) {
        bool zeroForOne = sqrtPriceCurrentX96 >= sqrtPriceTargetX96;

        uint256 amoutRemainingLessFee = PRBMath.mulDiv(amountRemaining, 1e6 - fee, 1e6);

        amountIn = zeroForOne
            ? Math.calcAmount0Delta(sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity, true)
            : Math.calcAmount1Delta(sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity, true);

        if (amoutRemainingLessFee >= amountIn) {
            sqrtPriceNextX96 = sqrtPriceTargetX96;
        } else {
            sqrtPriceNextX96 =
                Math.getNextSqrtPriceFromInput(sqrtPriceCurrentX96, liquidity, amoutRemainingLessFee, zeroForOne);
        }

        // 判断是否到了边界tick的情况
        bool max = sqrtPriceNextX96 == sqrtPriceTargetX96;

        if (zeroForOne) {
            amountIn = max ? amountIn : Math.calcAmount0Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, true);
            amountOut = Math.calcAmount1Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, false);
        } else {
            amountIn = max ? amountIn : Math.calcAmount1Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, true);
            amountOut = Math.calcAmount0Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, false);
        }

        // 如果在流动性充足的tick区间内，则按照 实际支付价格 - 实际支付的价格 x 费率 = 扣除手续费后的token数量
        // 如果max为true，则说明到达边界tick，流动性不足，只能交易部分数量。
        if (!max) {
            feeAmount = amountRemaining - amountIn;
        } else {
            feeAmount = Math.mulDivRoundingUp(amountIn, fee, 1e6 - fee);
        }
    }
}
