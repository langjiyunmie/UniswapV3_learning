// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.14;

import "./interfaces/IUniswapV3PoolDeployer.sol";
import "./UniswapV3Pool.sol";

/// @title  Uniswap V3 Factory 合约
/// @notice 负责部署并登记所有 Uniswap V3 池子，保证每对代币+手续费只创建一个确定性地址的池子
contract UniswapV3Factory is IUniswapV3PoolDeployer {
    // —— 错误定义 ——

    /// @notice 当两个传入代币地址相同，抛出该错误
    error TokensMustBeDifferent();
    /// @notice 当传入的手续费等级不在支持列表内，抛出该错误
    error UnsupportedFee();
    /// @notice 当传入零地址时，抛出该错误
    error ZeroAddressNotAllowed();
    /// @notice 当请求的池子已存在，抛出该错误
    error PoolAlreadyExists();

    // —— 事件 ——

    /// @notice 池子创建成功后发出事件，包含代币对、手续费、池子地址
    event PoolCreated(address indexed token0, address indexed token1, uint24 indexed fee, address pool);

    // —— 状态变量 ——

    /// @notice 将手续费等级映射到对应的 tickSpacing，用于构造池子时设置价格刻度间隔
    mapping(uint24 => uint24) public fees;

    /// @dev 临时存储下一个要创建的池子的构造参数，供 UniswapV3Pool 构造函数读取
    PoolParameters public parameters;

    /// @notice 存储已部署的池子地址：token0 => token1 => fee => poolAddress
    mapping(address => mapping(address => mapping(uint24 => address))) public pools;

    /// @notice 构造函数：注册默认支持的手续费等级与对应 tickSpacing
    constructor() {
        fees[500] = 10; // 0.05% 手续费，对应 tickSpacing = 10
        fees[3000] = 60; // 0.3%  手续费，对应 tickSpacing = 60
    }

    /// @notice 创建一个新的 Uniswap V3 池子，若已存在则失败
    /// @param tokenX 代币地址之一
    /// @param tokenY 代币地址之二
    /// @param fee    池子的交易手续费等级
    /// @return pool  新部署的池子合约地址
    function createPool(address tokenX, address tokenY, uint24 fee) public returns (address pool) {
        // 1. 校验：两个代币不能相同
        if (tokenX == tokenY) revert TokensMustBeDifferent();
        // 2. 校验：手续费等级必须已在 fees 映射中注册
        if (fees[fee] == 0) revert UnsupportedFee();
        // 3. 按地址大小排序，确保 token0 < token1，以保证后续 CREATE2 地址计算一致
        (tokenX, tokenY) = tokenX < tokenY ? (tokenX, tokenY) : (tokenY, tokenX);
        // 4. 校验：排序后第一个代币地址不能为零地址
        if (tokenX == address(0)) revert ZeroAddressNotAllowed();
        // 5. 校验：相同 (token0, token1, fee) 的池子尚未存在
        if (pools[tokenX][tokenY][fee] != address(0)) {
            revert PoolAlreadyExists();
        }

        // 6. 暂存构造参数，供新池子构造时读取
        parameters =
            PoolParameters({factory: address(this), token0: tokenX, token1: tokenY, tickSpacing: fees[fee], fee: fee});

        // 7. 使用 CREATE2 部署 UniswapV3Pool，salt 保证确定性地址
        pool = address(new UniswapV3Pool{salt: keccak256(abi.encodePacked(tokenX, tokenY, fee))}());

        // 8. 清理临时参数，避免残留
        delete parameters;

        // 9. 在映射中登记新池子地址（双向映射）
        pools[tokenX][tokenY][fee] = pool;
        pools[tokenY][tokenX][fee] = pool;

        // 10. 广播事件，链上/链下监听
        emit PoolCreated(tokenX, tokenY, fee, pool);
    }
}
