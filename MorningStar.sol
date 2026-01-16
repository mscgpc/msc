// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IPancakeRouter02} from "./IPancakeRouter02.sol";
import {IPancakePair} from "./IPancakePair.sol";
import {IUniswapV2Factory} from './IUniswapV2Factory.sol';
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {DEAD_WALLET} from "./Const.sol";
import "./IMSCOracle.sol";

contract MorningStar is OwnableUpgradeable,ReentrancyGuardUpgradeable{

    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;


    event BindReferral(address indexed user,address parent);
    event AddressUpdated(address indexed addr);
    event UserPermit(address user, bool status);
    event Addrecord(uint256 indexed,address user,uint256 amount);

    event Staked(
        address indexed user,
        uint256 star,
        uint256 usdt,
        uint256 price,
        uint256 timestamp
    );

    event UnStaked(
        address indexed user,
        uint256 star,
        uint256 price,
        uint256 timestamp
    );

    event UnstackMirror(
        address indexed user,
        uint256 totalSupply,
        uint256 balance,
        uint256 vip,
        uint256 total,
        uint256 tag,
        uint256 dync,
        uint256 star,
        uint256 staticAmount,
        uint256 dynamicAmount,
        uint256 msc,
        uint256 price,
        uint256 timestamp
    );

    event RewardPaid(
        address indexed user,
        uint256 reward,
        uint40 timestamp,
        uint256 index
    );

    event Transfer(address indexed from, address indexed to, uint256 amount);

    event ExpireBurn(address indexed user, uint256 amount, uint256 price, uint256 timestamp);
    event BatchExpireBurn(uint256 processedCount, uint256 currentIndex, uint256 timestamp);



  

    struct StarRecord{
        uint256 id;
        uint256 star;
        uint256 timestamp;
        uint256 starType;
        uint256 sign;  // 1 为正数，0 为负数
    } 


    struct WithdrawRecord{
        uint256 id;
        uint256 star;
        uint256 msc;
        uint256 timestamp;
    }

    struct StakeRecord {
        address user;
        address parent;
        uint256 msc;
        uint256 price;
        uint256 star;
        uint256 timestamp;
        uint256 parentStar;
        uint status;
    }

    // 算力规则
    // 1000U 
    uint256 public constant  LEVEL_1 = 1000 ether;
    uint256 public constant LEVEL_1_RATE = 200;
    // 10000U
    uint256 public constant  LEVEL_2 = 10000 ether;
    uint256 public constant LEVEL_2_RATE = 250;

    uint256 public constant LEVEL_3_RATE = 300;

    uint256 public constant MAX_PRICE_LENGTH = 100;

    uint256 public constant MIN_STAKE = 10 ether;
    uint256 public constant MAX_STAKE = 50000 ether;
    uint256 public constant STAKE_COLD_TIME = 1 minutes;

    uint256 public constant REDIRECT = 5;

    uint256 public constant BURN_MSC = 10;

    uint256 public constant PER_DAY_RELEASE = 1;

    uint256 public constant  V1_STAR = 10000 ether;
    uint256 public constant V1 = 5;


    uint256 public constant  V2_STAR = 50000 ether;
    uint256 public constant V2 = 10;

    uint256 public constant  V3_STAR = 200000 ether;
    uint256 public constant V3 = 15;

    uint256 public constant  V4_STAR = 1000000 ether;
    uint256 public constant V4 = 20;

    uint256 public constant  V5_STAR = 5000000 ether;
    uint256 public constant V5 = 30;

    uint256 public constant UNSTAKE_COLD_TIME = 24 hours; 
    uint256 public constant MAX_UNSTAKE_TIME = 180 days;

    uint8 public constant decimals = 18;
    string public constant name = "MORNING STAR STAKE";
    string public constant symbol = "MSCST";
 
 

    uint256 public totalSupply;
    mapping(address => uint256) public balances;

    mapping(address=>uint256) public totalStars;
    mapping(address=>uint256) public releaseStars;
    mapping(address=>uint256) public teamTotalInvestValue;
    mapping(address=>uint256) public unstakeTime;
    mapping(address=>uint256) public teamTotalCount;
    mapping(address=>uint256) public lastProfits;
    mapping(address=>StarRecord[]) public starRecords;
    mapping(address=>WithdrawRecord[]) public withdrawRecords;
    mapping(address=>bool) public joinFlag;
    mapping(address=>uint256) public joinTime;
    mapping(address=>uint256) public lastStakeTimes;
    mapping(address => bool) public isStop; // 地址冻结开关


    address[] public joinedAddress;
    uint256 public expireIndex;
    uint256 public  constant MAX_CIRCLE=50;
    uint256 public constant D_MAX=30;

    StakeRecord[] public records;

    mapping(address=>address[]) internal refferals;
    mapping(address=>address) internal belongTo;
    uint256 internal nonce;
    uint256 internal nonceWithdraw;
    address public msc;
    address public oracle;
    address public profit;
    address public rootAdd;

    

    modifier onlyEOA() {
        require(tx.origin == msg.sender, "EOA");
        _;
    }

    function initialize(address _profit_,address _rootAdd) public initializer{
       
        profit = _profit_;
        rootAdd = _rootAdd;
        bindReferral(address(this),rootAdd);
        __Ownable_init();   
        __ReentrancyGuard_init(); // 初始化父合约
        
        
    }


    function setMsc(address _msc_) public virtual onlyOwner{
        require(_msc_ != address(0), "Invalid address");
        msc = _msc_;
        emit AddressUpdated(_msc_);
    }

    function setAddressFreeze(address account, bool status) external onlyOwner {
        isStop[account] = status;
        emit UserPermit(account, status);
    }

      function setOracle(address _oracle_) public virtual onlyOwner{
        require(_oracle_ != address(0), "Invalid address");
        oracle = _oracle_;
        emit AddressUpdated(_oracle_);
     
    }

    function resetStake(uint256 recordIndex) external onlyOwner {
       StakeRecord storage record = records[recordIndex];
       require(record.status==0,'record is reset');
       record.status=1;
       address user = record.user;
       address parent = record.parent;
       uint256 userStar = record.star;
       uint256 parentStar = record.parentStar;
       if(balances[user] <userStar){
         userStar = balances[user];
       }
       uint256 price = IMSCOracle(oracle).mscPrice();
       if(userStar>0){
            burn(user,userStar,price,10);
       }
       if(balances[parent]>0){
        parentStar=balances[parent];
       }
       if(parentStar>0){
         burn(parent,parentStar,price,10);
       }
    }


    function balanceOf(address account)
        external
        view
        returns (uint256){
        return balances[account];
    }

    function syncBalance(address account,uint256 star) external onlyOwner{
        require(isBindReferral(account),'need bind');
        uint256 price = IMSCOracle(oracle).mscPrice();
        mint(account,star,0,price,0);

        records.push(StakeRecord({
             user: account,
             parent: getReferral(account),
             msc: 0,
             price:price,
             star:star,
             timestamp:block.timestamp,
             parentStar:0,
             status:0
        }));
        emit Addrecord(records.length-1,account,star);
    }

   
    function getReferral(address _address)public virtual view returns(address){
        return belongTo[_address];
    }

    function isBindReferral(address _address) public virtual view returns(bool){
        return belongTo[_address] !=address(0);
    }

    function getReferralCount(address _address) external virtual view returns(uint256){
        return refferals[_address].length;
    }

    function bindReferral(address _referral,address _user) public virtual {
        if(_referral == getRootAddress()){
            // 根目录只能是管理员加
            require(rootAdd==_user,'need root');
        }else{
            require(isBindReferral(_referral) ,'referral must  binded');
        }
        require(!isBindReferral(_user),'user is binded');
        
        refferals[_referral].push(_user);
        belongTo[_user] = _referral;
        joinTime[_user] = block.timestamp;
        joinedAddress.push(_user);

        address tmp = _user;
        uint256 index = 0;
        while(true){
            address parent = getReferral(tmp);
            if(parent==address(this)){
                break;
            }
            index++;
            teamTotalCount[parent] ++;
            tmp = parent;
        }


        emit BindReferral(_user, _referral);

    }

    function getReferrals(address _address) public virtual view returns(address[] memory){
        return refferals[_address];
    }

    function getRootAddress() public view returns(address){
        return address(this);
    }

    

    function unstake(address user) external  nonReentrant onlyEOA{
        require(block.timestamp - unstakeTime[user] >= UNSTAKE_COLD_TIME,'must at least 24 hours');
        require(!isStop[user] , "Address stopped");

        // 解压即提现
        uint256 price = IMSCOracle(oracle).mscPrice();
        uint256 balance = IERC20Upgradeable(msc).balanceOf(address(this));


        uint256 tag = balance*price*25/totalSupply/1e18;
        uint256 userStar = balances[user];
        uint256 dycn = 8 *  10000;
        if(tag < 20){
            dycn = balance * 10000 * 1000 * PER_DAY_RELEASE * price / totalSupply /100 /1e18;
        }
       
        uint256 staticAmount  = dycn * userStar /1000 /10000;
        
        (,uint256 totalStar,,uint256 vip,) = getUserVip(user);
        uint256 dynamicAmount = 0;

        if(vip == 1){
            dynamicAmount = dycn * totalStar  * V1 / 100 /1000 /10000 ;
        }else if(vip==2){
            dynamicAmount = dycn * totalStar  * V2 / 100 /1000 /10000;
        }else if(vip==3){
            dynamicAmount = dycn * totalStar  * V3 / 100/1000 / 10000;
        }else if(vip==4){
            dynamicAmount = dycn * totalStar  * V4 / 100/1000 / 10000;
        }else if(vip==5){
            dynamicAmount = dycn * totalStar  * V5 / 100/1000 / 10000;
        }
        uint256 totalAmount = staticAmount + dynamicAmount;
        

      
        lastProfits[user] = totalAmount;
        unstakeTime[user]=block.timestamp;
        uint256 totalMsc = totalAmount * 1e18 / price;
        require(totalMsc<=2*balance/100,'require less then 2%');
        emit UnstackMirror(
             user,
             totalSupply,
             balance,
             vip,
             totalStar,
             tag,
               dycn,
               totalAmount,
              staticAmount,
         dynamicAmount,
         totalMsc,
         price,
         block.timestamp
    );
      burn(user,totalAmount,price,3);

        nonceWithdraw++;
        withdrawRecords[user].push(WithdrawRecord({
              id:nonceWithdraw,
              star: totalAmount,
              msc: totalMsc,
             timestamp:block.timestamp
        }));
        uint256 totalFee = totalMsc / 10;
        IERC20Upgradeable(msc).safeTransfer(user,totalMsc-totalFee);

        releaseReward(totalFee);
        
        // 检查超过半年的自动释放掉下级
        burnExpireAll();

    }

    function releaseReward(uint256 fee) internal{
        IERC20Upgradeable(msc).safeTransfer(profit,fee);   
    }
    
    function burnExpire(address currentUser,uint256 price) internal{
        if (currentUser == address(0)) return; // 排除零地址
        if (unstakeTime[currentUser] == 0) return; // 无解锁记录
        if (balances[currentUser] == 0) return; // 无持仓
        // 2. 检查是否超过最大解锁时间
        uint256 timeElapsed = block.timestamp - unstakeTime[currentUser];
        if (timeElapsed > MAX_UNSTAKE_TIME) {
            uint256 burnAmount = balances[currentUser];
            // 调用燃烧函数（修复参数不匹配问题）
            burn(currentUser, burnAmount, price, 4);
            // 触发事件：便于链下监控
        }
    }
    

    function burnExpireAll() public {
        
        // 1. 边界条件：无用户时直接返回
        uint256 totalUsers = joinedAddress.length;
        if (totalUsers == 0) {
            emit BatchExpireBurn(0, expireIndex, block.timestamp);
            return;
        }

        // 2. 获取MSC价格（循环外获取，保证批量处理价格一致）
        uint256 price = IMSCOracle(oracle).mscPrice();
        require(price > 0, "Staking: MSC price is zero"); // 价格零值校验

        // 3. 安全循环：限制最大次数，避免Gas超限
        uint256 i = 0;
        uint256 processedCount = 0;
        while (i < MAX_CIRCLE) {
            // 安全获取当前用户：取模运算避免索引越界
            address currentUser = joinedAddress[expireIndex % totalUsers];
            // 燃烧当前用户过期持仓
            burnExpire(currentUser, price);

            // 4. 更新索引和计数
            expireIndex = (expireIndex + 1) % totalUsers; // 取模重置，避免越界
            i++;
            processedCount++;

            // 5. 提前终止：所有用户处理完毕（可选，根据业务需求）
            if (expireIndex == 0) break;
        }

        // 6. 触发批量事件
        emit BatchExpireBurn(processedCount, expireIndex, block.timestamp);
       
    }

    receive() external payable {
        dealReceive();
    }

      // 或者完全不实现 receive，依赖 fallback
    fallback() external payable {
        // 空实现，仅接收 BNB
        dealReceive();
    }

    function dealReceive() internal view{
        //require(msg.sender==address(this),'not support');
    }


    function staked(address user,uint256 amount) external nonReentrant onlyEOA{
        require(isBindReferral(user),'need bind');
        require(block.timestamp-lastStakeTimes[user] > STAKE_COLD_TIME,'cold time');
        require(block.timestamp-lastStakeTimes[msg.sender] > STAKE_COLD_TIME,'cold time');
        require(!isStop[user] , "Address stopped");
        lastStakeTimes[user]  = block.timestamp;
        lastStakeTimes[msg.sender] = block.timestamp;
        IERC20Upgradeable(msc).safeTransferFrom(msg.sender,address(this),amount);
        uint256 price = IMSCOracle(oracle).mscPrice();
        uint256 usdt = amount * price /1e18;  
        require(usdt>= MIN_STAKE && usdt<= MAX_STAKE,' stake amount error'); 
        addStar(user,usdt,price,amount);
        
        uint256 burnAmount = amount* BURN_MSC/MAX_PRICE_LENGTH;
        IERC20Upgradeable(msc).safeTransfer(DEAD_WALLET,burnAmount);
    }

    function addStar(address user,uint256 usdt,uint256 price,uint256 amount) internal{

        uint256 star = 0;
        if(usdt < LEVEL_1){
            star = usdt*LEVEL_1_RATE/MAX_PRICE_LENGTH;
        }else if(usdt < LEVEL_2){
            star = usdt*LEVEL_2_RATE/MAX_PRICE_LENGTH;
        }else{
            star = usdt*LEVEL_3_RATE/MAX_PRICE_LENGTH;
        }
        mint(user,star,usdt,price,1);
        unstakeTime[user]=block.timestamp; 
        // 直推
        uint256 tui = star * REDIRECT/MAX_PRICE_LENGTH;
        address parent = getReferral(user);
        if(parent != address(this)){
            if(tui <= balances[parent]){
                mint(parent,tui,0,price,2);
            }
        }
        records.push(StakeRecord({
             user: user,
             parent: parent,
             msc: amount,
             price:price,
             star:usdt,
             timestamp:block.timestamp,
             parentStar:tui,
             status:0
        }));
         emit Addrecord(records.length-1,user,star);
      
        burnExpireAll();
    }

 

    function burn(address sender,uint256 _star,uint256 _price,uint256 starType) internal{
        address tmp = sender;
        uint256 index = 0;
        while(true){
            address parent = getReferral(tmp);
            if(parent==address(this)){
                break;
            }
            if(index==D_MAX){
                break;
            }  
            index++;    
            teamTotalInvestValue[parent] -= _star;
            tmp = parent;
        }
        totalSupply -= _star;
        balances[sender] -= _star;
        teamTotalInvestValue[sender] -=_star;
        releaseStars[sender] +=_star;
        nonce++;
        starRecords[sender].push(StarRecord({
            id:nonce,
            star: _star ,
            timestamp:block.timestamp,
            starType: starType,
            sign:0
        }));
        if(balances[sender]==0){
            delete unstakeTime[sender]; 
        }
        emit Transfer(sender,address(0),  _star);
        emit UnStaked(sender, _star,_price,block.timestamp);
    }


    function mint(address sender, uint256 _star,uint256 _usdt,uint256 _price,uint256 starType) private {
        
        address tmp = sender;
        uint256 index = 0;
        while(true){
            address parent = getReferral(tmp);
            if(parent==address(this)){
                break;
            }
            if(index==D_MAX){
                break;
            }
            teamTotalInvestValue[parent] += _star;
            tmp = parent;
            index++;

        }
        if(!joinFlag[sender]){
            unstakeTime[sender]=block.timestamp; 
            joinFlag[sender] = true;
        }
     
        totalSupply += _star;
        balances[sender] += _star;
        totalStars[sender] +=_star;
        teamTotalInvestValue[sender] += _star;
        nonce++;
        starRecords[sender].push(StarRecord({
            id:nonce,
            star: _star ,
            timestamp:block.timestamp,
            starType: starType,
            sign:1
        }));
        emit Transfer(address(0), sender, _star);
        emit Staked(sender, _star,_usdt,_price,block.timestamp);
    }

    function getStarRecordCounts(address user) external view returns(uint256){
        return starRecords[user].length;
    }

    
       /**
     * @dev 获取用户的星级记录（倒序：最新→最早）
     * @param user 目标用户地址
     * @param length 期望返回的记录数量
     * @return records 星级记录数组（长度≤length，最新在前）
     */
    function getStarRecords(address user, uint256 length) external view returns (StarRecord[] memory) {
        // 1. 获取用户星级记录总数
        uint256 totalRecords = starRecords[user].length;
        
        // 边界条件：用户无星级记录，返回空数组
        if (totalRecords == 0) {
            return new StarRecord[](0);
        }

        // 2. 确定最终返回的记录数（取「期望长度」和「总记录数」的较小值）
        uint256 returnLength = length > totalRecords ? totalRecords : length;
        
        // 3. 创建返回数组（长度为returnLength）
        StarRecord[] memory starRecordArray = new StarRecord[](returnLength);
        
        // 4. 正向循环 + 计算倒序索引（避免uint256下溢）
        // 逻辑：i从0到returnLength-1，对应最新的returnLength条记录
        for (uint256 i = 0; i < returnLength; i++) {
            // 最新记录索引 = 总记录数 - 1 - 循环索引
            uint256 recordIndex = totalRecords - 1 - i;
            starRecordArray[i] = starRecords[user][recordIndex];
        }

        return starRecordArray;
    }
    

    function getUnStackedRecordCounts(address user) external view returns(uint256){
        return withdrawRecords[user].length;
    }

    function getUnStackedRecords(address user,uint256 length) external view returns(WithdrawRecord[] memory){
         // 1. 获取用户的提现记录总数
        uint256 totalRecords = withdrawRecords[user].length;
        
        // 边界条件：用户无记录，返回空数组
        if (totalRecords == 0) {
            return new WithdrawRecord[](0);
        }

        // 2. 确定最终返回的记录数量（取「期望长度」和「总记录数」的较小值）
        uint256 returnLength = length > totalRecords ? totalRecords : length;
        
        // 3. 创建返回数组（长度为returnLength）
        WithdrawRecord[] memory withdrawRecordArr = new WithdrawRecord[](returnLength);
        
        // 4. 倒序遍历（最新记录在前），避免uint256下溢
        // 循环逻辑：i从「最后一条记录索引」开始，到「最后一条 - returnLength + 1」结束
        for (uint256 i = 0; i < returnLength; i++) {
            // 最新记录索引：totalRecords - 1 - i
            uint256 recordIndex = totalRecords - 1 - i;
            withdrawRecordArr[i] = withdrawRecords[user][recordIndex];
        }

        return withdrawRecordArr;
    
    }

    function getUserVip(address user) public view returns(uint256,uint256,uint256,uint256,uint256){
        address[] memory referrals = getReferrals(user);
        address maxReferral = address(0);
        uint256 maxStar = 0;
        for(uint256 i=0;i<referrals.length;i++){
            if(teamTotalInvestValue[referrals[i]]> maxStar){
                maxReferral = referrals[i];
                maxStar = teamTotalInvestValue[maxReferral];
            }
        }
        uint256 totalStar = 0;
        for(uint256 i=0;i<referrals.length;i++){
            if(referrals[i] !=maxReferral ){
               totalStar+=teamTotalInvestValue[referrals[i]];
            }
        }
        uint256 realStar = totalStar;
        
        if(realStar >= balances[user] * 5){
            realStar = balances[user] * 5;
        }
        uint256 vip =0;
        if(realStar>=V5_STAR){
            vip = 5;
        }else if(realStar>=V4_STAR){
            vip = 4;
        }else if(realStar>=V3_STAR){
            vip = 3;
        }else if(realStar>=V2_STAR){
            vip = 2;
        }else if(realStar>=V1_STAR){
            vip = 1;

        }
        return (teamTotalInvestValue[user]-balances[user],realStar,maxStar,vip,totalStar);
    }


      uint256[255] private __gap;

   

}