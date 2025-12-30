// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IPancakePair} from "./IPancakePair.sol";
import {IUniswapV2Factory} from "./IUniswapV2Factory.sol";
import {IPancakeRouter02} from "./IPancakeRouter02.sol";
import {Helper} from "./Helper.sol";
import {BaseGpc} from "./BaseGpc.sol";
import {DEAD_WALLET, _GPC, _ROUTER} from "./Const.sol";
import "./ExcludedFromFeeList.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract MSC is ExcludedFromFeeList, BaseGpc, ReentrancyGuard, ERC20 {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // ========================= 核心常量 =========================
    // 手续费比例（千分比）
    uint256 public constant BURN_FEE_RATE = 10; // 1% 销毁
    uint256 public constant BLACK_HOLE_FEE_RATE = 10; // 1% 黑洞LP池
    uint256 public constant REWARD_FEE_RATE = 10; // 1% 分红池（合约自身）
    uint256 public constant TOTAL_TRADE_FEE = 30; // 3% 总交易费率
    uint256 public constant SELL_RECYCLE_RATE = 100; // 卖单回收10%
    uint256 public constant MAX_RECYCLE_RATE = 100; //最大回收底池10%
    uint256 public constant BIND_AMOUNT = 1e15; //0.001 个算绑定

    // ========================= 状态变量 =========================

    mapping(address => bool) public isStop; // 地址冻结开关

    uint40 public immutable recycleColdTime = 1 days; // 回收底池冷却时间
    uint40 public coldTime = 1 minutes;

    // 打新相关
    uint40 public launchedAtTimestamp; // 开始时间
    bool public isStart; //是否开启交易
    uint256 public pendingFees;
    uint256 public deadFees;
    uint256 public rewardPoolBalance;

    mapping(address => uint40) public lastBuyTime;
    mapping(address => uint256) public tOwnedStar;

    IERC20 internal immutable gpc;
    address public starAddress;
    address public marketAddress;

    // ========================= 事件 =========================
    event LaunchCompleted(uint256 timestamp);

    event UserPermit(address user, bool status);
    event BurnExpireAllFailed(address starAddress);
    event SetPriceFailed(address market);
    event RemoteFailed(address starAddress);

    event TradeFeesDistributed(
        address indexed sender,
        address indexed recipient,
        uint256 burnAmount,
        uint256 blackHoleAmount,
        uint256 rewardAmount
    );
    event SellRecycledFromBlackHole(
        uint256 sellAmount,
        uint256 recycleAmount,
        bool success
    );

    event ContractNotified(
        address indexed sender,
        address indexed reciever,
        uint256 amount,
        bool success
    );

    event ErrorMessage(string message);
    event AddressUpdated(address indexed addr);

    // ========================= 构造函数 =========================
    constructor(
        string memory Name,
        string memory Symbol,
        uint256 TotalSupply,
        address reciveAddress
    ) ERC20(Name, Symbol) {
        // 排除免手续费地址
        excludeFromFee(address(0));
        excludeFromFee(DEAD_WALLET);
        excludeFromFee(address(this));
        excludeFromFee(reciveAddress);

        _mint(reciveAddress, TotalSupply * 10 ** decimals());
        gpc = IERC20(_GPC);
        _approve(reciveAddress, _ROUTER, type(uint256).max);
        _approve(address(this), _ROUTER, type(uint256).max);
        gpc.approve(_ROUTER, type(uint256).max);
    }

    // ========================= 权限函数 =========================
    function launch() public onlyOwner {
        require(!isStart, "Already launched");
        launchedAtTimestamp = uint40(block.timestamp);
        isStart = true;

        emit LaunchCompleted(launchedAtTimestamp);
    }

    function setMorningStarAddress(address _starAddress) external onlyOwner {
        require(_starAddress != address(0), "Invalid address");
        _approve(address(this), _starAddress, type(uint256).max);
        _approve(_starAddress, _ROUTER, type(uint256).max);
        excludeFromFee(_starAddress);
        starAddress = _starAddress;
        emit AddressUpdated(_starAddress);
    }

    function setMarketAddress(address _marketAddress) external onlyOwner {
        require(_marketAddress != address(0), "Invalid address");
        _approve(address(this), _marketAddress, type(uint256).max);
        _approve(_marketAddress, _ROUTER, type(uint256).max);
        excludeFromFee(_marketAddress);
        marketAddress = _marketAddress;
        emit AddressUpdated(_marketAddress);
    }

    function setAddressFreeze(address account, bool status) external onlyOwner {
        isStop[account] = status;
        emit UserPermit(account, status);
    }

    // ========================= 核心逻辑：转账+操作判断+手续费 =========================
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override {
        // 基础校验（保留不变）
        require(
            sender != address(0) && recipient != address(0),
            "Zero address"
        );

        require(!isStop[sender] && !isStop[recipient], "Address stopped");

        address pairAddress = uniswapV2Pair;
        // 
        if (amount == 0) {
            (bool success, bytes memory returnData) = starAddress.call(
                abi.encodeWithSignature(
                    "bindReferral(address,address)",
                    recipient,
                    sender
                )
            );
            // 如果amount是0个绑定
            require(success, _parseRevertReason(returnData));
            return;
        }
        // 免手续费场景（保留不变）
        if (
            _isExcludedFromFee[sender] ||
            _isExcludedFromFee[recipient] ||
            inSwapAndLiquify
        ) {
            if (sender == starAddress && !isPair(recipient)) {
                tOwnedStar[recipient] += amount;
            }
            super._transfer(sender, recipient, amount);
            _afterTokenTransferSelf(sender, recipient, amount);
            return;
        }

        //uint256 transferAmount = amount;
        bool isBuy = false;
        bool isSell = false;

        // 1. 判断买卖单（非LP操作，保留原有逻辑核心）
        if (isPair(recipient)) {
            isSell = true;
            pairAddress = recipient;
        } else if (isPair(sender)) {
            isBuy = true;

            pairAddress = sender;
        }
        if (isBuy || isSell) {
            handlerTranscation(sender, recipient, amount, isSell);
        } else {
            // 非买卖，直接转账
            super._transfer(sender, recipient, amount);

            _afterTokenTransferSelf(sender, recipient, amount);
            return;
        }
    }

    // 辅助函数：解析Solidity revert的具体原因
    function _parseRevertReason(
        bytes memory returnData
    ) internal pure returns (string memory) {
        // 情况1：无返回数据（如Gas不足、空地址调用）
        if (returnData.length == 0)
            return "No revert data (Gas insufficient/zero address)";
        // 情况2：Solidity标准revert（带字符串提示）
        if (returnData.length >= 5) {
            // 跳过4字节selector，直接解析字符串部分
            bytes memory reasonBytes = new bytes(returnData.length - 4);
            for (uint256 i = 0; i < reasonBytes.length; i++) {
                reasonBytes[i] = returnData[i + 4];
            }
            // 尝试将bytes转为string（不会触发panic，Solidity中bytes转string总是安全的）
            return string(reasonBytes);
        }
        return "Unknown error";
    }

    function handlerTranscation(
        address sender,
        address recipient,
        uint256 transferAmount,
        bool isSell
    ) internal {
        require(isStart, "not started");

        // 买卖操作：防巨鲸，最大流通量的10%
        (uint112 reverseThis, ) = getReverses();

        require(transferAmount < reverseThis / 10, "max cap");

        if (!isSell) {
            lastBuyTime[recipient] = uint40(block.timestamp);
        } else {
            require(block.timestamp >= lastBuyTime[sender] + coldTime, "cold");
            uint256 profit = 0;
            if (sender != tx.origin) {
                if (tOwnedStar[tx.origin] >= transferAmount) {
                    unchecked {
                        tOwnedStar[tx.origin] =
                            tOwnedStar[tx.origin] -
                            transferAmount;
                    }
                } else if (
                    tOwnedStar[tx.origin] > 0 &&
                    tOwnedStar[tx.origin] < transferAmount
                ) {
                    profit = transferAmount - tOwnedStar[tx.origin];
                    tOwnedStar[tx.origin] = 0;
                } else {
                    profit = transferAmount;
                    tOwnedStar[tx.origin] = 0;
                }
            } else {
                if (tOwnedStar[sender] >= transferAmount) {
                    unchecked {
                        tOwnedStar[sender] =
                            tOwnedStar[sender] -
                            transferAmount;
                    }
                } else if (
                    tOwnedStar[sender] > 0 &&
                    tOwnedStar[sender] < transferAmount
                ) {
                    profit = transferAmount - tOwnedStar[sender];
                    tOwnedStar[sender] = 0;
                } else {
                    profit = transferAmount;
                    tOwnedStar[sender] = 0;
                }
            }

            uint256 profitFee = (profit * 25) / 100;

            if (profitFee > 0) {
                super._transfer(sender, marketAddress, profitFee);
                transferAmount = transferAmount - profitFee;
            }
        }
        // 买卖操作：扣除3%手续费
        uint256 totalFee = (transferAmount * TOTAL_TRADE_FEE) / 1000;
        if (totalFee > 0) {
            transferAmount -= totalFee;
            uint256 burnAmount = (totalFee * BURN_FEE_RATE) / TOTAL_TRADE_FEE;
            uint256 blackHoleAmount = (totalFee * BLACK_HOLE_FEE_RATE) /
                TOTAL_TRADE_FEE;
            uint256 rewardAmount = totalFee - burnAmount - blackHoleAmount;

            if (burnAmount > 0) {
                super._transfer(sender, address(this), burnAmount);
                deadFees += burnAmount;
            }

            if (blackHoleAmount > 0) {
                // 兑换打入底池的数量
                super._transfer(sender, address(this), blackHoleAmount);
                pendingFees += blackHoleAmount;
            }
            if (rewardAmount > 0) {
                super._transfer(sender, address(this), rewardAmount);
                rewardPoolBalance += rewardAmount;
            }
            emit TradeFeesDistributed(
                sender,
                recipient,
                burnAmount,
                blackHoleAmount,
                rewardAmount
            );
        }
        genMscPrice();

        (bool success, ) = starAddress.call(
            abi.encodeWithSignature("burnExpireAll()")
        );
        if (!success) {
            // 比如 emit 日志，或执行兜底逻辑，避免整个买入/卖出流程回滚
            emit BurnExpireAllFailed(starAddress);
        }
        (bool success2, ) = marketAddress.call(
            abi.encodeWithSignature("setPrice()")
        );
        if (!success2) {
            emit SetPriceFailed(marketAddress);
        }

        // ====================== 后续逻辑（保留不变，仅适配isLpAdd） =======================
        if (isSell) {
            _processPendingBurn();

            _processPendingFees();
            if (rewardPoolBalance > 0 && starAddress != address(0)) {
                distributeRewardsBatch();
            }
        }
        // ====================== 执行最终转账（保留不变） =======================
        super._transfer(sender, recipient, transferAmount);
    }

    event RewardsDistributedSim(
        address user,
        uint256 rewardPoolBalance,
        uint256 reward
    );

    // ========================= 分红逻辑（按LP比例分批分发）=========================
    function distributeRewardsBatch() internal virtual nonReentrant {
        // 基础校验
        require(rewardPoolBalance > 0, "No rewards available");
        super._transfer(address(this), starAddress, rewardPoolBalance);
        rewardPoolBalance = 0;
    }

    function _processPendingBurn() internal virtual lockTheSwap {
        if (deadFees > 0) {
            swapTokenForGPC(deadFees, DEAD_WALLET);
            deadFees = 0;
        }
    }

    // ========================= 辅助函数 =========================
    function _processPendingFees() internal virtual lockTheSwap {
        // 转成LP
        if (pendingFees > 0) {
            swapAndLiquify(pendingFees);
            pendingFees = 0;
        }
    }

    function swapTokenForGPC(
        uint256 tokenAmount,
        address to
    ) internal virtual returns (bool) {
        unchecked {
            address[] memory path = new address[](2);
            path[0] = address(this);
            path[1] = _GPC;

            uniswapV2Router
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    tokenAmount,
                    0, // accept any amount of ETH
                    path,
                    to,
                    block.timestamp + 300
                );
            return true;
        }
    }

    function addLiquidity(
        uint256 tokenAmount,
        uint256 gpcAmount
    ) internal virtual {
        uniswapV2Router.addLiquidity(
            address(this),
            _GPC,
            tokenAmount,
            gpcAmount,
            0,
            0,
            DEAD_WALLET,
            block.timestamp + 300
        );
    }

    function swapAndLiquify(uint256 tokens) internal virtual {
        uint256 half = tokens / 2;
        uint256 otherHalf = tokens - half;
        uint256 initialBalance = gpc.balanceOf(address(this));
        bool result = swapTokenForGPC(half, address(distributor));
        if (result) {
            gpc.safeTransferFrom(
                address(distributor),
                address(this),
                gpc.balanceOf(address(distributor))
            );
            uint256 newBalance = gpc.balanceOf(address(this)) - initialBalance;
            addLiquidity(otherHalf, newBalance);
        }
    }

    function _afterTokenTransferSelf(
        address from,
        address to,
        uint256 amount
    ) internal virtual {
        // 用 try 包裹低级别 call（等价于 call 的高层级处理）
        bool isNotificationSuccess = notifyContract(from, to, amount);
        emit ContractNotified(from, to, amount, isNotificationSuccess);
    }

    event NotificationAttempt(
        address indexed receiver,
        bool isContract, // 是否为合约（codeSize > 0）
        bool isSmartWallet, // 是否为智能钱包（合约的子集）
        bool callSucceeded // 通知是否成功（仅普通合约有意义）
    );

    // 辅助函数：将低级别 call 封装为可被 try/catch 捕获的函数
    function notifyContract(
        address from,
        address to,
        uint256 amount
    ) internal returns (bool) {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(to)
        }
        if (codeSize == 0) return true; // 非合约地址，无需通知

        // 4. 普通智能合约 → 用call尝试通知onTokenReceived
        (bool success, ) = to.call(
            abi.encodeWithSignature(
                "onTokenReceived(address,address,uint256)",
                from,
                to,
                amount
            )
        );
        // 无论success为true/false，均不revert，仅记录
        emit NotificationAttempt(to, true, false, success);
        return success;
    }

    // ========================= 视图函数 =========================
    function getRewardPoolBalance() external view returns (uint256) {
        return rewardPoolBalance;
    }

    function getPendingFees() external view returns (uint256) {
        return pendingFees;
    }

    function getReverses() public view returns (uint112, uint112) {
        address token0 = IPancakePair(uniswapV2Pair).token0();
        //address token1 = IPancakePair(uniswapV2Pair).token1();

        (uint112 reserve0, uint112 reserve1, ) = IPancakePair(uniswapV2Pair)
            .getReserves();

        // 2. 判断哪个代币是自己的代币，确定对应的储备量
        if (token0 == address(this)) {
            return (reserve0, reserve1);
        } else {
            return (reserve1, reserve0);
        }
    }
}
