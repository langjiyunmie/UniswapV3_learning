// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.14;

import "./FixedPoint96.sol";
import "lib/prb-math/contracts/PRBMath.sol";

library Math {
    function calcAmount0Delta(
        uint160 sqrtPriceAx96,
        uint160 sqrtPriceBx96,
        uint128 liquidity,
        // 当为true是进行向上取整，false则为向下取整
        bool roundUp
    ) internal pure returns (uint256 amount0) {
        if (sqrtPriceAx96 > sqrtPriceBx96) {
            (sqrtPriceAx96, sqrtPriceBx96) = (sqrtPriceBx96, sqrtPriceAx96);
        }
        require(sqrtPriceAx96 > 0);

        uint256 numerator1 = uint256(liquidity) << FixedPoint96.RESOLUTION;
        uint256 numerator2 = sqrtPriceBx96 - sqrtPriceAx96;

        if (roundUp) {
            amount0 = divRoundingUp(mulDivRoundingUp(numerator1, numerator2, sqrtPriceBx96), sqrtPriceAx96);
        } else {
            amount0 = PRBMath.mulDiv(numerator1, numerator2, sqrtPriceBx96) / sqrtPriceAx96;
        }
    }

    function calcAmount1Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (roundUp) {
            amount1 = mulDivRoundingUp(liquidity, (sqrtPriceBX96 - sqrtPriceAX96), FixedPoint96.Q96);
        } else {
            amount1 = PRBMath.mulDiv(liquidity, (sqrtPriceBX96 - sqrtPriceAX96), FixedPoint96.Q96);
        }
    }

    function calcAmount0Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, int128 liquidity)
        internal
        pure
        returns (int256 amount0)
    {
        amount0 = liquidity < 0
            ? -int256(calcAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, uint128(-liquidity), false))
            : int256(calcAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, uint128(liquidity), true));
    }

    function calcAmount1Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, int128 liquidity)
        internal
        pure
        returns (int256 amount1)
    {
        amount1 = liquidity < 0
            ? -int256(calcAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, uint128(-liquidity), false))
            : int256(calcAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, uint128(liquidity), true));
    }

    //向上取整
    function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        //向下取整
        result = PRBMath.mulDiv(a, b, denominator);
        //检查余数
        if (mulmod(a, b, denominator) > 0) {
            require(result < type(uint256).max);
            result++;
        }
    }

    //向上取整
    function divRoundingUp(uint256 numerator, uint256 denominator) internal pure returns (uint256 result) {
        assembly {
            result :=
                add(
                    //div 是 EVM 的除法指令，计算 numerator / denominator，结果向下取整
                    div(numerator, denominator),
                    //如果余数大于0 ，返回true -- 1
                    gt(mod(numerator, denominator), 0)
                )
        }
    }

    function getNextSqrtPriceFromInput(uint160 sqrtPriceX96, uint128 liquidity, uint256 amountIn, bool zeroForOne)
        internal
        pure
        returns (uint160 sqrtPriceNextX96)
    {
        sqrtPriceNextX96 = zeroForOne
            ? getNextSqrtPriceFromAmount0Rounding(sqrtPriceX96, liquidity, amountIn)
            : getNextSqrtPriceFromAmount1RoundingDown(sqrtPriceX96, liquidity, amountIn);
    }

    function getNextSqrtPriceFromAmount0Rounding(uint160 sqrtPriceX96, uint128 liquidity, uint256 amountIn)
        internal
        pure
        returns (uint160)
    {
        uint256 numerator = uint256(liquidity) << FixedPoint96.RESOLUTION;
        uint256 product = amountIn * sqrtPriceX96;
        //如果 product 溢出，product的值将从0开始，如果product = amountIn * sqrtPriceX96 是正确的（未溢出），那么 (amountIn * sqrtPriceX96) / amountIn 应该等于 sqrtPriceX96。
        if (product / amountIn == sqrtPriceX96) {
            uint256 denominator = numerator + product;
            return uint160(mulDivRoundingUp(numerator, sqrtPriceX96, denominator));
        }
        //如果 product 溢出
        return uint160(divRoundingUp(numerator, (numerator / sqrtPriceX96) + amountIn));
    }

    function getNextSqrtPriceFromAmount1RoundingDown(uint160 sqrtPriceX96, uint128 liquidity, uint256 amountIn)
        internal
        pure
        returns (uint160)
    {
        return sqrtPriceX96 + uint160((amountIn << FixedPoint96.RESOLUTION) / liquidity);
    }
}
