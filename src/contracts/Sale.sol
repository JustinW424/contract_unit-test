// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/access/Ownable.sol";
import "openzeppelin-solidity/contracts/utils/Address.sol";

/*
 *   _____    ____    _____   _   _   ______  _____  __   __
 *  / ____|  / __ \  |_   _| | \ | | |___  / |_   _| \ \ / /
 * | |      | |  | |   | |   |  \| |    / /    | |    \ V / 
 * | |      | |  | |   | |   | . ` |   / /     | |     > <  
 * | |____  | |__| |  _| |_  | |\  |  / /__   _| |_   / . \ 
 *  \_____|  \____/  |_____| |_| \_| /_____| |_____| /_/ \_\
 *                                                                                                                    
 */


interface IPancakeSwap {
    function WETH() external pure returns (address);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

contract Sale is Ownable {
    IERC20 public token;
    bool public test = true; //test

    struct Stage {
        // deposit info
        uint256 startTimestamp;
        uint256 endTimestamp;
        uint256 hardCapInTokens;
        uint256 totalDistributedTokens;
        uint256 thousandTokensPriceInUSDT;
        uint256 minDepositInUSDT;
        uint256 maxDepositInUSDT;

        // vesting conditions
        uint256 firstReleasePercent;
        uint256 minPeriod;
        uint256 percentPerPeriod;
        uint256 offsetTime;
    }

    struct Lock {
        uint256 totalLockedTokens;
        // vesting conditions
        uint256 firstReleasePercent;
        uint256 minPeriod;
        uint256 percentPerPeriod;
        uint256 offsetTime;
        uint256 totalClaimed;
    }

    bool public isListed;

    struct User {
        uint256 totalTokens;
        uint256 totalClaimed;
    }

    struct Locker {
        uint256 totalTokens;
        uint256 totalClaimed;
    }

    uint256 public tgeTimestamp;

    //      account    =>    stageIndex => data
    mapping(address => User[]) public users;
    mapping(address => Locker[]) public lockers;

    Stage[] public stages;
    Lock[] public locks;


    mapping(address => bool) public whitelist;

    uint256 public constant DENOMINATOR = 10000;
    uint256 public constant PRICE_DENOMINATOR = 1000;

//    address USDTAddress = 0x55d398326f99059fF775485246999027B3197955; // mainnet
    address USDTAddress = 0x40D7c8F55C25f448204a140b5a6B0bD8C1E48b13; // testnet
    IPancakeSwap public router;

    constructor() {
//        token = IERC20(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82); //Cake token mainnet
        token = IERC20(0x2ea8c131b84a11f8CCC7bfdC6abE6A96341b8673); //test token testnet
//        initDEXRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E); // mainnet bsc
        initDEXRouter(0x14e9203E14EF89AB284b8e9EecC787B1743AD285); // testnet bsc
        whitelist[msg.sender] = true;
    }
    function initDEXRouter(address _router) public onlyOwner {
        IPancakeSwap _pancakeV2Router = IPancakeSwap(_router);
        router = _pancakeV2Router;
    }

    function addStage(
        uint256 startTimestamp, uint256 endTimestamp,
        uint256 hardCapInTokens, uint256 thousandTokensPriceInUSDT,
        uint256 minDepositInUSDT, uint256 maxDepositInUSDT,
        uint256 firstReleasePercent, uint256 minPeriod, uint256 percentPerPeriod, uint256 offsetTime
    ) public onlyOwner {
        require(stages.length < 3);
        require(startTimestamp < endTimestamp);
        require(minDepositInUSDT < maxDepositInUSDT);
        require(firstReleasePercent > 100 && firstReleasePercent <= DENOMINATOR, "Should be passed with DENOMINATOR");
        require(minPeriod > 0 && percentPerPeriod > 0);

        stages.push(
            Stage(
                startTimestamp,
                endTimestamp,
                hardCapInTokens,
                0,
                thousandTokensPriceInUSDT,
                minDepositInUSDT,
                maxDepositInUSDT,
                firstReleasePercent,
                minPeriod,
                percentPerPeriod,
                offsetTime
            )
        );
    }

    function addLock(
        uint256 firstReleasePercent, uint256 minPeriod, uint256 percentPerPeriod, uint256 offsetTime
    ) public onlyOwner {
        require(firstReleasePercent >= 100 && firstReleasePercent <= DENOMINATOR, "Should be passed with DENOMINATOR");
        require(minPeriod > 0 && percentPerPeriod > 0);

        locks.push(
            Lock(
                0,
                firstReleasePercent,
                minPeriod,
                percentPerPeriod,
                offsetTime,
                0
            )
        );
    }

    receive() payable external {
        deposit();
    }

    // 0 - private sale, 1,2 - public sale, 3 -> finished or not started
    function currentStage() view public returns (uint256) {
        for (uint256 i = 0; i < stages.length; i++) {
            if (block.timestamp > stages[i].startTimestamp && block.timestamp < stages[i].endTimestamp) {
                return i;
            }
        }
        return 3;
    }

    function reachedHardCap() view public returns (bool) {
        require(currentStage() < 3, 'Sales finished or not started');
        return stages[currentStage()].hardCapInTokens == stages[currentStage()].totalDistributedTokens;
    }

    function remainTokensOfAddress(address account) view public returns (uint256) {
        User[] memory user = users[account];
        uint256 amount;
        for (uint256 i = 0; i < stages.length; i++) {
            amount += user[i].totalTokens - user[i].totalClaimed;
        }
        return amount;
    }

    function claimable(address account, uint256 time) view external returns (uint256) {
        uint256 amount;
        for (uint256 i = 0; i < stages.length; i++) {
            amount += claimableByStageIndex(i, account, time);
        }
        return amount;
    }

    function claimableByStageIndex(uint256 stageIndex, address account, uint256 time) view public returns (uint256) {
        require(stageIndex < stages.length);
        if (!isListed) {
            return 0;
        }

        User memory user = users[account][stageIndex];
        uint256 absolutePercent = _absolutePercentageByStageIndex(stageIndex, time);
        uint256 absoluteAmount = user.totalTokens * absolutePercent / DENOMINATOR;
        if (absoluteAmount < user.totalClaimed) {
            return 0;
        }
        uint256 claimableAmount = absoluteAmount - user.totalClaimed;
        return claimableAmount;
    }

    function claimableByLockIndex(uint256 lockIndex, address account, uint256 time) view public returns (uint256) {
        require(lockIndex < locks.length);
        if (!isListed) {
            return 0;
        }

        Locker memory locker = lockers[account][lockIndex];
        uint256 absolutePercent = _absolutePercentageByLockIndex(lockIndex, time);
        uint256 absoluteAmount = locker.totalTokens * absolutePercent / DENOMINATOR;
        if (absoluteAmount < locker.totalClaimed) {
            return 0;
        }
        uint256 claimableAmount = absoluteAmount - locker.totalClaimed;
        return claimableAmount;
    }

    function _absolutePercentageByStageIndex(uint256 stageIndex, uint256 time) view private returns (uint256) {
        Stage memory stage = stages[stageIndex];

        uint256 totalPercent = stage.firstReleasePercent;

        if (time == 0) {
            time = block.timestamp;
        }

        if (stage.offsetTime < time - tgeTimestamp) {
            uint256 deltaTime = time - tgeTimestamp - stage.offsetTime;
            uint256 periods = deltaTime / stage.minPeriod;
            if (periods == 0) {
                return totalPercent;
            }

            totalPercent += periods * stage.percentPerPeriod;
            if (totalPercent > DENOMINATOR) {
                return DENOMINATOR;
            }
        }

        return totalPercent;
    }

    function _absolutePercentageByLockIndex(uint256 lockIndex, uint256 time) view private returns (uint256) {
        Lock memory lock = locks[lockIndex];

        uint256 totalPercent = lock.firstReleasePercent;

        if (time == 0) {
            time = block.timestamp;
        }

        if (lock.offsetTime < time - tgeTimestamp) {
            uint256 deltaTime = time - tgeTimestamp - lock.offsetTime;
            uint256 periods = deltaTime / lock.minPeriod;
            if (periods == 0) {
                return totalPercent;
            }

            totalPercent += periods * lock.percentPerPeriod;
            if (totalPercent > DENOMINATOR) {
                return DENOMINATOR;
            }
        }

        return totalPercent;
    }

    function claim() external {
        require(isListed, 'Not listed');
        uint256 amountByStage;
        uint256 toSendAmount;
        User[] storage userStages = users[msg.sender];
        for (uint256 i = 0; i < stages.length; i++) {
            amountByStage = claimableByStageIndex(i, msg.sender, block.timestamp);
            if (amountByStage > 0) {
                if (amountByStage > userStages[i].totalTokens - userStages[i].totalClaimed) {
                    amountByStage = userStages[i].totalTokens - userStages[i].totalClaimed;
                }
                userStages[i].totalClaimed += amountByStage;
                toSendAmount += amountByStage;
            }
        }
        if (toSendAmount > 0) {
            token.transfer(msg.sender, toSendAmount);
            emit Claimed(msg.sender, toSendAmount);
        }
    }

    function claimTeamVesting(uint256 lockIndex) external {
        require(isListed, 'Not listed');
        uint256 amountByLock;
        Locker[] storage userLocks = lockers[msg.sender];
        amountByLock = claimableByLockIndex(lockIndex, msg.sender, block.timestamp);
        if (amountByLock > 0) {
            if (amountByLock > userLocks[lockIndex].totalTokens - userLocks[lockIndex].totalClaimed) {
                amountByLock = userLocks[lockIndex].totalTokens - userLocks[lockIndex].totalClaimed;
            }
            userLocks[lockIndex].totalClaimed += amountByLock;
            locks[lockIndex].totalClaimed += amountByLock;
        }
        if (amountByLock > 0) {
            token.transfer(msg.sender, amountByLock);
            emit Claimed(msg.sender, amountByLock);
        }
    }

    function calculateUSDTFromBNB(uint256 BNBAmount) public view returns (uint256) {
        address[] memory path;
        path = new address[](2);
        path[0] = router.WETH();
        path[1] = USDTAddress;

        uint256 usdtAmount = router.getAmountsOut(BNBAmount, path)[1];

        return usdtAmount;
    }

    function deposit() public payable {
        require(msg.value > 0, 'Insufficient amount');
        require(whitelist[msg.sender] == true, "Account is not in whitelist");
        require(!reachedHardCap(), "Hard Cap is already reached");
        uint256 stageIndex = currentStage();
        Stage storage stage = stages[stageIndex];
        uint256 userStages = users[msg.sender].length;
        uint256 stagesAmount = stages.length;
        if (userStages < stagesAmount) {
            for (uint256 i = 0; i < stagesAmount-userStages; i++) {
                users[msg.sender].push(User(0,0));
            }
        }
        User storage userByStageIndex = users[msg.sender][stageIndex];

        uint256 usdtAmount = calculateUSDTFromBNB(msg.value);

        require(usdtAmount >= stage.minDepositInUSDT && usdtAmount <= stage.maxDepositInUSDT, 'Deposited amount is less or grater than allowed range.');

        uint256 tokensAmount = usdtAmount * PRICE_DENOMINATOR / stage.thousandTokensPriceInUSDT;
        uint256 tokensToSend = tokensAmount;

        if (tokensAmount + stage.totalDistributedTokens > stage.hardCapInTokens) {
            tokensToSend = stage.hardCapInTokens - stage.totalDistributedTokens;
            uint256 sendBackBNBAmount = msg.value * (tokensAmount - tokensToSend) / tokensAmount;
            (bool success, ) = msg.sender.call{value: sendBackBNBAmount}("");
            require(success, 'Cant send back bnb');
        }

        stage.totalDistributedTokens += tokensToSend;
        userByStageIndex.totalTokens += tokensToSend;

        emit Deposited(msg.sender, tokensToSend);
    }

    function lockTokens(uint256 lockIndex, address account, uint256 amount) public onlyOwner {
        Lock storage  lock = locks[lockIndex];
        uint256 lockerLocks = lockers[account].length;
        uint256 locksAmount = locks.length;
        if (lockerLocks < locksAmount) {
            for (uint256 i = 0; i < locksAmount-lockerLocks; i++) {
                lockers[account].push(Locker(0,0));
            }
        }
        Locker storage lockerByLockIndex = lockers[account][lockIndex];

        lock.totalLockedTokens += amount;
        lockerByLockIndex.totalTokens += amount;
        emit Locked(lockIndex, account, amount);
    }

    function setListed(uint256 _timestamp) external onlyOwner {
        require(stages[0].endTimestamp != 0, "Sales not started");
        require(currentStage() == 3, "Presale not finished");
        isListed = true;
        if (_timestamp < block.timestamp) {
            _timestamp = block.timestamp;
        }
        tgeTimestamp = _timestamp;
        emit Listed(tgeTimestamp);
    }

    function releaseFunds(uint256 bnbAmount) external onlyOwner {
        if (bnbAmount == 0) {
            bnbAmount = address(this).balance;
        }

        require(bnbAmount > 0, "Insufficient amount");
        (bool success, ) = msg.sender.call{value: bnbAmount}("");
        require(success, 'Cant release');
    }

    function lockedTokensAmount() public view returns(uint256) {
        uint256 result;
        for (uint256 i = 0; i < locks.length; i++) {
            result += locks[i].totalLockedTokens - locks[i].totalClaimed;
        }
        return result;
    }

    function releaseTokens(uint256 tokensAmount) external onlyOwner {
        uint256 locked = lockedTokensAmount();
        uint256 balance = token.balanceOf(address(this));
        uint256 releasable = locked < balance ? (balance - locked) : 0;

        if (tokensAmount == 0 || tokensAmount > releasable) {
            tokensAmount = releasable;
        }

        require(tokensAmount > 0, "Insufficient amount");
        token.transfer(msg.sender, tokensAmount);
    }

    function addWhiteList(address payable _address) external onlyOwner {
        whitelist[_address] = true;
    }

    function removeWhiteList(address payable _address) external onlyOwner {
        whitelist[_address] = false;
    }

    function addWhiteListMulti(address[] calldata _addresses) external onlyOwner {
        require(_addresses.length <= 10000, "Provide less addresses in one function call");
        for (uint256 i = 0; i < _addresses.length; i++) {
            whitelist[_addresses[i]] = true;
        }
    }

    function removeWhiteListMulti(address[] calldata _addresses) external onlyOwner {
        require(_addresses.length <= 10000, "Provide less addresses in one function call");
        for (uint256 i = 0; i < _addresses.length; i++) {
            whitelist[_addresses[i]] = false;
        }
    }

    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(IERC20(tokenAddress) != token, "Can't recover sale token");
        IERC20(tokenAddress).transfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    // usdt decimals needed
    function setMinDepositAmount(uint256 stageIndex, uint256 usdtAmount) external onlyOwner {
        Stage storage stage = stages[stageIndex];
        require(usdtAmount < stage.maxDepositInUSDT, "Min value should be less than max value");
        emit UpdateMinDepositAmount(stageIndex, stage.minDepositInUSDT, usdtAmount);
        stage.minDepositInUSDT = usdtAmount;
    }

    function setMaxDepositAmount(uint256 stageIndex, uint256 usdtAmount) external onlyOwner {
        Stage storage stage = stages[stageIndex];
        require(usdtAmount > stage.minDepositInUSDT, "Max value should be greater than min value");
        emit UpdateMinDepositAmount(stageIndex, stage.maxDepositInUSDT, usdtAmount);
        stage.maxDepositInUSDT = usdtAmount;
    }

    function setThousandTokensPriceInUSDT(uint256 stageIndex, uint256 usdtAmountForThousandTokens) external onlyOwner {
        Stage storage stage = stages[stageIndex];
        require(usdtAmountForThousandTokens > 0, "USDT amount should be greater than zero");
        emit UpdateThousandTokensPriceInUSDT(stageIndex, stage.thousandTokensPriceInUSDT, usdtAmountForThousandTokens);
        stage.thousandTokensPriceInUSDT = usdtAmountForThousandTokens;
    }

    function setHardCapInTokens(uint256 stageIndex, uint256 tokensAmount) external onlyOwner {
        Stage storage stage = stages[stageIndex];
        require(stage.totalDistributedTokens <= tokensAmount, "Hard cap should be greater");
        emit UpdateHardCapInTokens(stageIndex, stage.hardCapInTokens, tokensAmount);
        stage.hardCapInTokens = tokensAmount;
    }

    function setSaleTime(uint256 stageIndex, uint256 start, uint256 end) external onlyOwner {
        Stage storage stage = stages[stageIndex];
        require(start < end && start > 0 && end > block.timestamp);

        if (start < block.timestamp) {
            start = block.timestamp;
        }

        emit UpdateSaleTime(stageIndex, stage.startTimestamp, stage.endTimestamp, start, end);
        stage.startTimestamp = start;
        stage.endTimestamp = end;
    }

    // 100% == 10000
    function setFirstReleasePercent(uint256 stageIndex, uint256 percent) external onlyOwner {
        Stage storage stage = stages[stageIndex];
        require(percent <= DENOMINATOR, "Percent should be less(equal) than 100");
        emit UpdateFirstReleasePercent(stageIndex, stage.firstReleasePercent, percent);
        stage.firstReleasePercent = percent;
    }

    function setClaimConditions(uint256 stageIndex, uint256 minPeriod, uint256 percentPerPeriod, uint256 offsetTime) external onlyOwner {
        Stage storage stage = stages[stageIndex];
        require(minPeriod > 0 && percentPerPeriod > 0);

        emit UpdateClaimConditions(stageIndex,
            stage.minPeriod, stage.percentPerPeriod, stage.offsetTime,
            minPeriod, percentPerPeriod, offsetTime);

        stage.minPeriod = minPeriod;
        stage.percentPerPeriod = percentPerPeriod;
        stage.offsetTime = offsetTime;
    }


    event UpdateMinDepositAmount(uint256 stageIndex, uint256 oldValue, uint256 newValue);
    event UpdateMaxDepositAmount(uint256 stageIndex, uint256 oldValue, uint256 newValue);
    event UpdateThousandTokensPriceInUSDT(uint256 stageIndex, uint256 oldValue, uint256 newValue);
    event UpdateHardCapInTokens(uint256 stageIndex, uint256 oldValue, uint256 newValue);
    event UpdateSaleTime(uint256 stageIndex, uint256 oldStart, uint256 oldEnd, uint256 newStart, uint256 newEnd);
    event UpdateFirstReleasePercent(uint256 stageIndex, uint256 oldPercent, uint256 newPercent);
    event UpdateClaimConditions(uint256 stageIndex,
        uint256 oldMinPeriod, uint256 oldPercentPerPeriod, uint256 oldOffsetTime,
        uint256 minPeriod, uint256 percentPerPeriod, uint256 offsetTime);
    event Deposited(address indexed user, uint256 usdtAmount);
    event Locked(uint256 lockIndex,address indexed account, uint256 amount);
    event SendBack(address indexed user, uint256 amount);
    event Recovered(address token, uint256 amount);
    event Claimed(address account, uint256 amount);
    event Listed(uint256 timestamp);
}
