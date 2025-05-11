// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.14;

import "node_modules/solidity-bytes-utils/contracts/BytesLib.sol";

library BytesLibExt {
    function toUint24(bytes memory _bytes, uint256 _start) internal pure returns (uint24) {
        require(_bytes.length >= _start + 3, "toUint24_outOfBounds");
        uint24 tempUint;

        assembly {
            //读取 3 字节
            tempUint := mload(add(add(_bytes, 0x3), _start))
        }

        return tempUint;
    }
}

library Path {
    using BytesLib for bytes;
    using BytesLibExt for bytes;

    // 一个以太坊地址的长度是 20 字节。
    uint256 private constant ADDR_SIZE = 20;
    // tick 间隔（uint24 类型）的长度是 3 字节。
    uint256 private constant TICKSPACING_SIZE = 3;
    // 跳到下一个代币地址的偏移量。一个池子的部分数据包括：输入代币地址（20 字节）+ tick 间隔（3 字节），共 23 字节。
    uint256 private constant NEXT_OFFSET = ADDR_SIZE + TICKSPACING_SIZE;
    // 一个完整池子参数的长度：输入代币（20 字节）+ tick 间隔（3 字节）+ 输出代币（20 字节）= 43 字节。
    uint256 private constant POP_OFFSET = NEXT_OFFSET + ADDR_SIZE;
    // 包含至少两个池子的路径最小长度：第一个池子（43 字节）+ 第二个池子的部分数据（23 字节）= 66 字节。
    uint256 private constant MULTIPLE_POOLS_MIN_LENGTH = POP_OFFSET + NEXT_OFFSET;

    //单池路径：WETH, 60, USDC，长度 = 20 + 3 + 20 = 43 字节 < 66 → 返回 false。
    //多池路径：WETH, 60, USDC, 10, USDT，长度 = 20 + 3 + 20 + 3 + 20 = 66 字节 ≥ 66 → 返回 true。
    function hasMultiplePools(bytes memory path) internal pure returns (bool) {
        return path.length >= MULTIPLE_POOLS_MIN_LENGTH;
    }

    //路径：WETH, 60, USDC, 10, USDT, 60, WBTC，长度 = 20 + 3 + 20 + 3 + 20 + 3 + 20 = 89 字节。
    //计算：(89 - 20) / 23 = 69 / 23 = 3 → 3 个池子。
    function numPools(bytes memory path) internal pure returns (uint256) {
        return (path.length - ADDR_SIZE) / NEXT_OFFSET;
    }

    //提取路径中第一个池子的字节序列（43 字节）
    function getFirstPool(bytes memory path) internal pure returns (bytes memory) {
        return path.slice(0, POP_OFFSET);
    }

    //跳过路径中的第一个代币和 tickSpacing，返回剩余的路径。
    function skipToken(bytes memory path) internal pure returns (bytes memory) {
        return path.slice(NEXT_OFFSET, path.length - NEXT_OFFSET);
    }

    //解码路径中第一个池子的信息，返回输入代币、输出代币和 tickSpacing
    function decodeFirstPool(bytes memory path)
        internal
        pure
        returns (address tokenIn, address tokenOut, uint24 tickSpacing)
    {
        tokenIn = path.toAddress(0);
        tickSpacing = path.toUint24(ADDR_SIZE);
        tokenOut = path.toAddress(NEXT_OFFSET);
    }
}
