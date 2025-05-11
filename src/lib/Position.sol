// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.14;

import "prb-math/PRBMath.sol";
import "./LiquidityMath.sol";
import "./FixedPoint128.sol";

library Position {
    // Info 结构体定义了 LP 在某个价格区间（由 lowerTick 和 upperTick 确定）内的头寸信息
    struct Info {
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokenOwed0;
        uint128 tokenOwed1;
    }

    function get(mapping(bytes32 => Info) storage self, address owner, int24 lowerTick, int24 upperTick)
        internal
        view
        returns (Position.Info storage position)
    {
        position = self[keccak256(abi.encodePacked(upperTick, lowerTick, owner))];
    }

    function update(
        Info storage self,
        int128 liquidityDelta,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) internal {
        // 将费用增长按当前流动性比例转换为实际的 token0 数量。
        uint128 tokensOwed0 = uint128(
            PRBMath.mulDiv(feeGrowthInside0X128 - self.feeGrowthInside0LastX128, self.liquidity, FixedPoint128.Q128)
        );

        uint128 tokensOwed1 = uint128(
            PRBMath.mulDiv(feeGrowthInside1X128 - self.feeGrowthInside1LastX128, self.liquidity, FixedPoint128.Q128)
        );

        self.liquidity = LiquidityMath.addLiquidity(self.liquidity, liquidityDelta);
        self.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        self.feeGrowthInside1LastX128 = feeGrowthInside1X128;

        if (tokensOwed0 > 0 || tokensOwed1 > 0) {
            self.tokenOwed0 += tokensOwed0;
            self.tokenOwed1 += tokensOwed1;
        }
    }
}
