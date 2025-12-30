// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;
import {IPancakePair} from "./IPancakePair.sol";
import {IUniswapV2Factory} from "./IUniswapV2Factory.sol";
import {IPancakeRouter02} from "./IPancakeRouter02.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {_GPC, _ROUTER,_WBNB,_USDC,_USDT,DEAD_WALLET} from "./Const.sol";
import "./IMSC.sol";

contract MSCMarket is Ownable,ReentrancyGuard{

    using SafeMath for uint256;
    using SafeERC20 for IERC20;


    event AddressUpdated(address indexed addr);

    uint256 public constant SELL_RATE = 1;
    uint256 public constant BUY_RATE = 10;
    uint256 public constant SELL_PRICE = 5;
    uint256 public constant BUY_PRICE = 10;

    uint256 public constant FOR_GPC_COLD=30 minutes;
    uint256 public constant FOR_MAX_GPC = 100 ether;
    uint256 public constant FOR_GPC_RATE=1;
    uint256 public lastGPC = 0;



    address public msc;
   

    IPancakeRouter02 internal uniswapV2Router;
    address internal uniswapV2PairGpc;
   
    IERC20 internal gpc;
    IERC20 internal usdt;

    uint256 public lastPrice;



    constructor(){
      
        gpc = IERC20(_GPC);
        uniswapV2Router = IPancakeRouter02(_ROUTER);
        gpc.forceApprove( _ROUTER, type(uint256).max);
        usdt = IERC20(_USDT);
        usdt.forceApprove( _ROUTER, type(uint256).max);

        address factory = uniswapV2Router.factory();
        uniswapV2PairGpc = IUniswapV2Factory(factory).getPair(
                _GPC,
                uniswapV2Router.WETH()
            )
        ;
       
    }


    function setMsc(address _msc_) public virtual onlyOwner{
        require(_msc_ != address(0), "Invalid address");
        msc = _msc_;
        IERC20(msc).forceApprove( _ROUTER, type(uint256).max);
        emit AddressUpdated(_msc_);
     
    }


    function  setPrice() external nonReentrant{
        require(msg.sender==msc,'msc error');
        if(lastPrice==0){
            lastPrice = IMSC(msc).mscPrice(15 minutes);
            return;
        }
        // 触发交易
        // 
        if(usdt.balanceOf(address(this))==0){
            // 卖出0.1%
            if(IERC20(msc).balanceOf(address(this))>0){
                uint256 fee = IERC20(msc).balanceOf(address(this))* SELL_RATE/1000;
                swapTokenForUSDT(fee,address(this));
            }
            lastPrice = IMSC(msc).mscPrice(15 minutes);
            return;
        }
        uint256 currentPrice =IMSC(msc).mscPrice(15 minutes);
        if(currentPrice>=lastPrice*(100+SELL_PRICE)/100){
            if(IERC20(msc).balanceOf(address(this))>0){
                uint256 fee = IERC20(msc).balanceOf(address(this))* SELL_RATE/1000;       
                swapTokenForUSDT(fee,address(this));
            }
            lastPrice = currentPrice;
        }else if(currentPrice<=lastPrice*(100-BUY_PRICE)/1000){
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


}