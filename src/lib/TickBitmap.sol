// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity >=0.5.0;

import "./BitMath.sol";

library TickBitmap {
    /// @notice 计算给定 tick 在 bitmap 中对应的 word 下标和 bit 下标
    /// @param tick 要定位的 tick 值（已除以 tickSpacing 后的值）
    /// @return wordPos 这个 tick 落在哪个 256-bit 的“桶”（word）中
    /// @return bitPos 这个 tick 在该 word 内的哪一位（0…255）
    function position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
        // wordPos = tick >> 8，相当于除以 256，向下取整，确定落在哪个 uint256 槽
        wordPos = int16(tick >> 8);
        // bitPos = tick % 256，取余得到在该槽内的具体位索引
        bitPos = uint8(uint24(tick % 256));
    }

    /// @notice 翻转（flip）某个 tick 的激活状态：未激活→激活，或已激活→未激活
    /// @dev 对应文档 “Flips the initialized state for a given tick from false to true, or vice versa”:contentReference[oaicite:0]{index=0}
    /// @param self 底层的 bitmap 映射：wordPos => 256-bit 状态位图
    /// @param tick 要翻转的 tick（原始 tick 值，需要是 tickSpacing 的整数倍）
    /// @param tickSpacing tick 的间隔，只有能被 tickSpacing 整除的 tick 才能初始化
    function flipTick(mapping(int16 => uint256) storage self, int24 tick, int24 tickSpacing) internal {
        // 确保 tick 对齐到 tickSpacing；否则不允许在此处翻转
        require(tick % tickSpacing == 0);
        // 计算落在哪个 word 和哪个 bit
        (int16 wordPos, uint8 bitPos) = position(tick);

        // 在该 bitPos 位置构造掩码：1 << bitPos
        uint256 mask = 1 << bitPos;
        // XOR 翻转该位：0→1（激活），1→0（清除）
        self[wordPos] ^= mask;
    }

    /// @notice 在同一个 256-bit word 内，寻找紧邻给定 tick 之上或之下的已初始化 tick
    /// @param self 底层 bitmap
    /// @param tick 当前 tick（原始值）
    /// @param tickSpacing tick 的间隔
    /// @param lte 如果为 true，找 ≤ tick 的最近已初始化 tick；否则找 > tick 的最近已初始化 tick
    /// @return next 找到的下一个 tick 值
    /// @return initialized 在该 word 内是否存在这样的初始化位
    function nextInitializedTickWithinOneWord(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        // 将原始 tick 压缩到 “槽 index” 上：除以 tickSpacing
        int24 compressed = tick / tickSpacing; // 向下取整
        // 负数且有余数时，要再减 1 才是向下取整
        if (tick < 0 && tick % tickSpacing != 0) compressed--;

        if (lte) {
            // —— 向左（≤ tick）搜索
            (int16 wordPos, uint8 bitPos) = position(tick);
            // 构造掩码：从 0 到 bitPos 全部置 1
            // (1<<bitPos) - 1 生成低 bitPos 位全 1，再加上 (1<<bitPos) 本位
            uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
            // 只保留已初始化的那些位
            uint256 masked = self[wordPos] & mask;
            // 如果任何位被置 1，就说明在此 word 内存在已初始化 tick
            initialized = masked != 0;
            next = initialized
                // 找到最高有效位的位置（mostSignificantBit）
                ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                // 否则就退回到本 word 的最左端（未初始化）
                : (compressed - int24(uint24(bitPos))) * tickSpacing;
        } else {
            // —— 向右（> tick）搜索
            (int16 wordPos, uint8 bitPos) = position(tick);
            // 构造掩码：从 bitPos+1 到 255 全部置 1
            uint256 mask = ~((1 << bitPos) - 1);
            uint256 masked = self[wordPos] & mask;
            initialized = masked != 0;
            next = initialized
                // 找到最低有效位（leastSignificantBit）
                ? (compressed + 1 + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                // 否则到本 word 的最右端
                : (compressed + 1 + int24(uint24(type(uint8).max) - bitPos));
        }
    }
}
