// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;
import {IPancakePair} from "./IPancakePair.sol";
import {IUniswapV2Factory} from "./IUniswapV2Factory.sol";
import {IPancakeRouter02} from "./IPancakeRouter02.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {_GPC, _ROUTER,_WBNB,_USDC,_USDT,DEAD_WALLET} from "./Const.sol";
import "./IMSCOracle.sol";

contract MSCMarket is OwnableUpgradeable,ReentrancyGuardUpgradeable{

    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;


    event AddressUpdated(address indexed addr);

    uint256 public constant SELL_RATE = 1;
    uint256 public constant BUY_RATE = 10;
    uint256 public constant SELL_PRICE = 5;
    uint256 public constant BUY_PRICE = 10;

    uint256 public constant FOR_GPC_COLD=60 minutes;
    uint256 public constant FOR_MAX_GPC = 100 ether;
    uint256 public constant FOR_GPC_RATE=10;
    uint256 public lastGPC;



    address public msc;
   

    IPancakeRouter02 internal uniswapV2Router;
    address internal uniswapV2PairGpc;
   
    IERC20Upgradeable internal gpc;
    IERC20Upgradeable internal usdt;

    uint256 public lastPrice;
    address public profitUser;
    address public oracle;

    function initialize(address _profit)public initializer{
      
        gpc = IERC20Upgradeable(_GPC);
        uniswapV2Router = IPancakeRouter02(_ROUTER);
        gpc.forceApprove( _ROUTER, type(uint256).max);
        usdt = IERC20Upgradeable(_USDT);
        usdt.forceApprove( _ROUTER, type(uint256).max);

        address factory = uniswapV2Router.factory();
        uniswapV2PairGpc = IUniswapV2Factory(factory).getPair(
                _GPC,
                uniswapV2Router.WETH()
            )
        ;
        profitUser = _profit;
        __Ownable_init();  
        __ReentrancyGuard_init(); // 初始化父合约
    }


    function setMsc(address _msc_) public virtual onlyOwner{
        require(_msc_ != address(0), "Invalid address");
        msc = _msc_;
        IERC20Upgradeable(msc).forceApprove( _ROUTER, type(uint256).max);
        emit AddressUpdated(_msc_);
     
    }

    function setOracle(address _oracle_) public virtual onlyOwner{
        require(_oracle_ != address(0), "Invalid address");
        oracle = _oracle_;
        emit AddressUpdated(_oracle_);
     
    }


    function  setPrice() external nonReentrant{
        if(lastPrice==0){
            lastPrice = IMSCOracle(oracle).mscPriceTime(15 minutes);
            return;
        }
        // 触发交易
        // 
        if(usdt.balanceOf(address(this))==0){
            // 卖出0.1%
            if(IERC20Upgradeable(msc).balanceOf(address(this))>0){
                uint256 fee = IERC20Upgradeable(msc).balanceOf(address(this))* SELL_RATE/1000;
                swapTokenForUSDT(fee,address(this));
            }
            lastPrice = IMSCOracle(oracle).mscPriceTime(15 minutes);
            return;
        }
        uint256 currentPrice =IMSCOracle(oracle).mscPriceTime(15 minutes);
        if(currentPrice>=lastPrice*(100+SELL_PRICE)/100){
            if(IERC20Upgradeable(msc).balanceOf(address(this))>0){
                uint256 fee = IERC20Upgradeable(msc).balanceOf(address(this))* SELL_RATE/1000;       
                swapTokenForUSDT(fee,address(this));
            }
            lastPrice = currentPrice;
        }else if(currentPrice<=lastPrice*(100-BUY_PRICE)/100){
            if(usdt.balanceOf(address(this)) >0){
                swapUSDTForToken(usdt.balanceOf(address(this))*BUY_RATE/1000, address(this));
            }
            lastPrice = currentPrice;
        }
        if(lastGPC + FOR_GPC_COLD< block.timestamp ){
            uint256 forGPCUSDT = usdt.balanceOf(address(this)) * FOR_GPC_RATE/10000;
            if(forGPCUSDT > FOR_MAX_GPC){
                forGPCUSDT = FOR_MAX_GPC;
            }
            swapUSDTForGPC(forGPCUSDT,uniswapV2PairGpc);
            IPancakePair(uniswapV2PairGpc).sync(); 
            lastGPC = block.timestamp;

        }
    }
    function swapUSDTForGPC(uint256 tokenAmount,address to) internal virtual returns(bool){
        unchecked {
            address[] memory path = new address[](3);
            path[0] = _USDT;
            path[1] = _WBNB;
            path[2] = _GPC;
            uniswapV2Router
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    tokenAmount,
                    0, // accept any amount of ETH
                    path,
                    to,
                    block.timestamp+300
            );
            return true;
        }
    }


    function swapTokenForUSDT(uint256 tokenAmount, address to) internal virtual returns(bool){
        unchecked {
            address[] memory path = new address[](4);
            path[0] = msc;
            path[1] = _GPC;
            path[2] = _WBNB;
            path[3] = _USDT;
            uniswapV2Router
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    tokenAmount,
                    0, // accept any amount of ETH
                    path,
                    to,
                    block.timestamp+300
            );
            return true;
        }
    }

    function swapUSDTForToken(uint256 tokenAmount, address to) internal virtual returns(bool){
        unchecked {
            address[] memory path = new address[](4);
            path[0] = _USDT;
            path[1] = _WBNB;
            path[2] = _GPC;
            path[3] = msc;
            uniswapV2Router
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    tokenAmount,
                    0, // accept any amount of ETH
                    path,
                    to,
                    block.timestamp+300
            );
            return true;
        }
    }

    receive() external payable {
        dealReceive();
    }

      // 或者完全不实现 receive，依赖 fallback
    fallback() external payable {
        // 空实现，仅接收 BNB
        dealReceive();
    }

    function dealReceive() internal {
        require(msg.sender==profitUser,'not support');
        require(msg.value==0,'not support');
        IERC20Upgradeable(msc).safeTransfer(profitUser,IERC20Upgradeable(msc).balanceOf(address(this)));
        IERC20Upgradeable(_USDT).safeTransfer(profitUser,IERC20Upgradeable(_USDT).balanceOf(address(this)));
        IERC20Upgradeable(_GPC).safeTransfer(profitUser,IERC20Upgradeable(_GPC).balanceOf(address(this)));
    }


    uint256[255] private __gap;


}