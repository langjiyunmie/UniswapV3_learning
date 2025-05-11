// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.14;

library Oracle {
    struct Observation {
        uint32 timestamp;
        int56 tickCumulative;
        bool initialized;
    }

    // 初始化函数，在部署或首次使用时调用，设置第一个观测点
    function initialize(Observation[65535] storage self, uint32 time)
        internal
        returns (uint16 cardinality, uint16 cardinalityNext)
    {
        // 在槽位 0 写入初始观测
        self[0] = Observation({timestamp: time, tickCumulative: 0, initialized: true});
        // 返回值：
        // cardinality：当前已使用槽位数量（最小 1）
        // cardinalityNext：下次调用 grow 扩容时的目标大小
        cardinality = 1;
        cardinalityNext = 1;
    }

    // 写入一个新的观测点（或覆盖旧观测），在每次池子交互后调用更新
    function write(
        Observation[65535] storage self, // 环形缓冲区，存储所有观测点
        uint16 index, // 当前最新观测在数组中的下标
        uint32 timestamp, // 本次写入的区块时间戳
        int24 tick, // 本次写入时的最新 tick 值
        uint16 cardinality, // 当前缓冲区中已初始化的观测数量
        uint16 cardinalityNext // 下次扩容后的目标缓冲区大小
    ) internal returns (uint16 indexUpdated, uint16 cardinalityUpdated) {
        // 取出数组中指向的最新观测
        Observation memory last = self[index];

        // 如果最新观测的时间戳已和本次相同，则说明本区块已写过，直接返回不做更新
        if (last.timestamp == timestamp) return (index, cardinality);

        // 如果缓冲区需要扩容（cardinalityNext > cardinality）且刚好走到最后一个槽，
        // 那么就把初始化数量更新到新的大小
        if (cardinalityNext > cardinality && index == (cardinality - 1)) {
            cardinalityUpdated = cardinalityNext;
        } else {
            // 否则保持原有已初始化数量
            cardinalityUpdated = cardinality;
        }

        // 计算下一个写入的下标：当前下标 +1，然后对有效容量取模，实现环形覆盖
        indexUpdated = (index + 1) % cardinalityUpdated;

        // 在计算出的位置上写入一个新观测，使用 transform 用上一次观测和当前 tick/time 来生成
        self[indexUpdated] = transform(last, timestamp, tick);
    }

    function transform(
        Observation memory last, // 传入的“最后一条”观测（上一次记录的 timestamp、tickCumulative 等）
        uint32 timestamp, // 要“填充”到的目标时间戳（通常是当前区块的时间）
        int24 tick // 目标时间点的最新 tick 值
    ) internal pure returns (Observation memory) {
        // 计算从上一次观测到目标时间的时间差（秒数）
        uint56 delta = timestamp - last.timestamp;

        // 构造并返回一个新的 Observation：
        //  - 使用目标时间戳
        //  - 在上一次的 tickCumulative 基础上，加上这段时间内按最新 tick 线性累积的数值
        //  - 标记为已初始化
        return Observation({
            timestamp: timestamp, // 更新为目标时间
            tickCumulative: last.tickCumulative // 累积值 = 旧累积 +
                + int56(tick) //                最新 tick
                    * int56(delta), //                时间差
            initialized: true // 新观测已初始化
        });
    }

    // 预先在 Observation 环形缓冲区里“打标记”，为未来可能要写入的新槽位做准备，从而避免在 write 时出现未初始化的坑
    function grow(Observation[65535] storage self, uint16 current, uint16 next) internal returns (uint16) {
        // 如果目标长度 next 不大于当前长度 current，根本不需要扩容，直接返回 current，什么都不做
        if (next <= current) return current;
        // 由于在 Observation 里，只有 timestamp != 0 的条目才被视作“已初始化”，这一操作等同于“把这些槽位先标记成可用”，但还没真正写入具体的 tickCumulative
        for (uint16 i = current; i < next; i++) {
            self[i].timestamp = 1;
        }

        return next;
    }

    /// @dev 在“环形”时间戳空间（uint32 溢出）中比较 a ≤ b
    function lte(
        uint32 time, // 当前参考时间戳（秒），uint32 范围 0…2^32−1
        uint32 a, // 要比较的第一个时间戳
        uint32 b // 要比较的第二个时间戳
    ) private pure returns (bool) {
        // 如果 a、b 都不“绕圈”——即都 ≤ 当前 time，直接按普通大小比
        if (a <= time && b <= time) return a <= b;

        // 否则，至少有一个已经溢出回到 0，需要把它“拉回”到更高区间
        // 如果 a > time，说明 a 属于“下一圈”，不变；否则，把 a + 2^32 拉到下一圈
        uint256 aAdjusted = a > time ? a : a + 2 ** 32;
        // 同理处理 b
        uint256 bAdjusted = b > time ? b : b + 2 ** 32;

        // 在统一空间里比较“拉回后”的大小
        return aAdjusted <= bAdjusted;
    }

    function binarySearch(
        Observation[65535] storage self, // 环形缓冲区，存储按时间顺序的观测点
        uint32 time, // 当前区块时间戳（秒）
        uint32 target, // 我们要定位的“目标时间戳”（time - secondsAgo）
        uint16 index, // 指向最新观测在数组中的下标
        uint16 cardinality // 数组中实际已初始化的观测数量
    ) private view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        uint256 l = (index + 1) % cardinality; // index的 下一个位置
        // 最大范围。使用二分法查找时，需要覆盖所有的范围。所以从 (index + 1) 开始再到下一个循环的 index 为总范围
        uint256 r = l + cardinality - 1;
        uint256 i;
        while (true) {
            // beforeOrAt：时间戳 ≤ target 的观测，离 target 最近的那一条。
            // atOrAfter：时间戳 ≥ target 的观测，离 target 最近的那一条。
            // (beforeOrAt.timestamp) ≤ target ≤ (atOrAfter.timestamp)

            i = (l + r) / 2;
            // 取“中点”观测，注意要对 cardinality 取模回到环形缓冲区的下标
            beforeOrAt = self[i % cardinality];

            // 如果这条观测还没初始化（timestamp==0），说明 i 落到了“预留槽”，
            //     我们要往右侧继续（缩小搜索区间）
            if (beforeOrAt.initialized) {
                l = i + 1;
                continue; // 回到 while 开始下一轮
            }
            // 否则，这条观测已可用，取它的“下一个”作为 atOrAfter
            //     （同样要 mod cardinality）
            atOrAfter = self[(i + 1) % cardinality];

            // 判断 target 是否在 beforeOrAt 与 atOrAfter 之间：
            //     （1）target ≥ beforeOrAt.timestamp
            //     （2）target ≤ atOrAfter.timestamp
            bool targetAtOrAfter = lte(time, beforeOrAt.timestamp, target);

            if (targetAtOrAfter && lte(time, target, atOrAfter.timestamp)) {
                // 同时满足两端条件，就找到了包围 target 的观测对，跳出循环
                break;
            }
            // 如果 target < beforeOrAt.timestamp，说明 target 在“中点”左边，
            //     把右边界 r 移到 i−1，继续在左半区间搜索
            if (!targetAtOrAfter) {
                r = i - 1;
            }
            // 否则说明 target > atOrAfter.timestamp（超在中点右边），
            //     把左边界 l 移到 i+1，继续在右半区间搜索
            else {
                l = i + 1;
            }
            // 循环结束后，beforeOrAt 和 atOrAfter 就分别是“目标前或等于”和“目标准或等于”那两个观测
        }
    }

    function getSurroundingObservations(
        Observation[65535] storage self, // 环形缓冲区：存储所有历史观测
        uint32 time, // 当前区块的时间戳（秒级）
        uint32 target, // 查询的目标时间戳（time - secondsAgo）
        int24 tick, // 最新的 tick 值，用于补齐最新观测
        uint16 index, // 环形缓冲区中指向“最新”观测的下标
        uint16 cardinality // 当前已初始化的观测数量（≤ 数组长度）
    ) private view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        // 1. 默认把最新观测赋给 beforeOrAt
        beforeOrAt = self[index];

        // 2. 如果 target 在“最新观测”的时间戳之后或刚好等于它
        if (lte(time, beforeOrAt.timestamp, target)) {
            // 2.1 若恰好等于最新观测的时间戳，则直接返回该观测，atOrAfter 不用
            if (beforeOrAt.timestamp == target) {
                return (beforeOrAt, atOrAfter);
            } else {
                // 2.2 若 target 在最新观测之后，但在当前区块内，用 transform 补齐一条“虚拟观测”
                //     把最新观测推进到 target 时间，以最新 tick 线性累积
                return (beforeOrAt, transform(beforeOrAt, target, tick));
            }
        }

        // 3. 若 target 在最新观测之前，则切换到“最老”那条观测
        beforeOrAt = self[(index + 1) % cardinality];
        // 如果该槽位尚未初始化（timestamp==0），说明环还没完全填满，用第 0 个槽
        if (!beforeOrAt.initialized) beforeOrAt = self[0];

        // 4. 如果 target 比最老观测还要早，则超出可查询范围，抛错
        require(lte(time, beforeOrAt.timestamp, target), "OLD");

        // 5. 否则，target 在“最老”和“最新”之间，用二分查找精确定位包围它的两条观测
        return binarySearch(self, time, target, index, cardinality);
    }

    function observeSingle(
        Observation[65535] storage self, // 环形数组，存储所有历史观测
        uint32 time, // 当前区块时间戳（秒级）
        uint32 secondsAgo, // 查询目标距离当前“几秒前”
        int24 tick, // 当前最新 tick，用于补齐最新观测
        uint16 index, // 环形数组中“最新”观测的下标
        uint16 cardinality // 数组中有效（已初始化）观测的数量
    ) internal view returns (int56 tickCumulative) {
        // 1. 如果要查询“0 秒前”（也就是当前时刻），直接取最新观测
        if (secondsAgo == 0) {
            Observation memory last = self[index]; // 读取最新观测
            // 1.1 如果最新观测的 timestamp 小于当前时间（time），说明还没写“现在”这一刻
            if (last.timestamp != time) {
                // 补齐一条“临时观测”：用当前 time 和 tick 更新累积值
                last = transform(last, time, tick);
            }
            return last.tickCumulative; // 返回最新（或补齐后）的累积 tick
        }

        // 2. 计算要查询的“过去时间戳” target = 当前时间 - secondsAgo
        uint32 target = time - secondsAgo;

        // 3. 在环形缓冲区中找到包围 target 的两条观测：
        //    beforeOrAt.timestamp ≤ target ≤ atOrAfter.timestamp
        (Observation memory beforeOrAt, Observation memory atOrAfter) =
            getSurroundingObservations(self, time, target, tick, index, cardinality);

        // 4. 如果 target 恰好等于左侧观测，直接返回它的累积值
        if (target == beforeOrAt.timestamp) {
            return beforeOrAt.tickCumulative;
        }
        // 5. 如果 target 恰好等于右侧观测，直接返回它的累积值
        else if (target == atOrAfter.timestamp) {
            return atOrAfter.tickCumulative;
        }
        // 6. 否则，target 在两观测之间，需要做线性插值
        else {
            // 6.1 计算两观测之间的时间差（秒）
            uint56 observationTimeDelta = atOrAfter.timestamp - beforeOrAt.timestamp;
            // 6.2 计算从左侧观测到 target 的时间差
            uint56 targetDelta = target - beforeOrAt.timestamp;
            // 6.3 插值公式：left + (right-left) / timeDelta * targetDelta
            return beforeOrAt.tickCumulative
                + ((atOrAfter.tickCumulative - beforeOrAt.tickCumulative) / int56(observationTimeDelta))
                    * int56(targetDelta);
        }
    }

    function observe(
        Observation[65535] storage self, // 环形数组，存储所有历史观测
        uint32 time, // 当前区块时间戳（秒级）
        uint32[] memory secondsAgos, // 用户要查询的多个“几秒前”数组
        int24 tick, // 当前最新 tick，用于补齐最新观测
        uint16 index, // 环形数组中“最新”观测的下标
        uint16 cardinality // 数组中有效（已初始化）观测的数量
    ) internal view returns (int56[] memory tickCumulatives) {
        // 1. 新建一个 int56 数组，用于存放每个查询时刻对应的累积 tick
        tickCumulatives = new int56[](secondsAgos.length);

        // 2. 遍历所有要查询的 secondsAgo 值
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            // 2.1 对第 i 个 secondsAgo 调用 observeSingle，计算对应的累积 tick
            tickCumulatives[i] = observeSingle(
                self, // 环形观测数组
                time, // 当前时间
                secondsAgos[i], // “几秒前”值
                tick, // 最新 tick
                index, // 最新观测下标
                cardinality // 有效观测数量
            );
        }
        // 3. 循环结束后，tickCumulatives 数组即包含了所有指定时间点的累积 tick
    }
}
