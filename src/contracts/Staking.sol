// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/access/Ownable.sol";
import "openzeppelin-solidity/contracts/security/ReentrancyGuard.sol";
import "openzeppelin-solidity/contracts/token/ERC20/utils/SafeERC20.sol";

/*
 *   _____    ____    _____   _   _   ______  _____  __   __
 *  / ____|  / __ \  |_   _| | \ | | |___  / |_   _| \ \ / /
 * | |      | |  | |   | |   |  \| |    / /    | |    \ V / 
 * | |      | |  | |   | |   | . ` |   / /     | |     > <  
 * | |____  | |__| |  _| |_  | |\  |  / /__   _| |_   / . \ 
 *  \_____|  \____/  |_____| |_| \_| /_____| |_____| /_/ \_\
 *                                                                                                                    
 */

contract Staking is Ownable {
    using SafeERC20 for IERC20;
    IERC20 public token;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 rewardLockedUp;
        uint256 nextHarvestUntil;
    }

    struct WithdrawPending {
        uint256 reserved;
        uint256 endOfPending;
    }

    uint256 public lastRewardTimestamp;
    uint256 accTokenPerShare;

    uint256 public minDeposit;
    uint256 public constant HARVEST_INTERVAL = 3 minutes;
    uint256 public withdrawPendingPeriod;

    uint256 public tokenPerDay;
    uint256 public totalLockedUpRewards;

    uint256 public totalStaked;
    uint256 public totalPaid;
    uint256 public tokensForReward;
    uint256 public startTimestamp;

    mapping (address => UserInfo) public userInfo;
    mapping (address => WithdrawPending) public withdrawPending;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event AddWithdrawPending(address indexed user, uint256 amount);
    event RewardLockedUp(address indexed user, uint256 amountLockedUp);
    event UpdateWithdrawPendingPeriod(uint256 oldValue, uint256 newValue);

    constructor(address _tokenAddress, uint256 _decimals) {
        token = IERC20(_tokenAddress);
        tokenPerDay = 1000 * 10 ** (_decimals - 1); // 100 per day period
        withdrawPendingPeriod = 10 minutes;
        minDeposit = 1 * 10 ** _decimals;
    }

    function startStaking(uint256 _timestamp) public onlyOwner {
        require(_timestamp > block.timestamp, 'Provide future time');
        startTimestamp = _timestamp;
        lastRewardTimestamp = startTimestamp;
    }

    function updateWithdrawPendingPeriod(uint256 _pendingPeriodInDays) external onlyOwner {
        require(_pendingPeriodInDays > 0 && _pendingPeriodInDays <= 30, 'Provide days from 1 to 30');
        uint256 pendingInDays = _pendingPeriodInDays * 1 minutes;
        emit UpdateWithdrawPendingPeriod(withdrawPendingPeriod, pendingInDays);
        withdrawPendingPeriod = pendingInDays;
    }

    function setMinDeposit(uint256 _minDeposit) external onlyOwner {
        minDeposit = _minDeposit;
    }

    function getMultiplier(uint256 _from) public view returns (uint256) {
        if (lastRewardTimestamp == 0) {
            return 0;
        }
        return (block.timestamp - _from) / 10 minutes;
    }

    function pendingToken(address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 _accTokenPerShare = accTokenPerShare;

        if (block.timestamp > lastRewardTimestamp && totalStaked != 0) {
            uint256 multiplier = getMultiplier(lastRewardTimestamp);
            uint256 tokenReward = multiplier * tokenPerDay;
            _accTokenPerShare += (tokenReward * 1e12 / totalStaked);
        }
        return user.amount * _accTokenPerShare / 1e12 - user.rewardDebt;
    }

    function canHarvest(address _account) public view returns (bool) {
        UserInfo storage user = userInfo[_account];
        if (user.nextHarvestUntil < startTimestamp + HARVEST_INTERVAL) {
            return block.timestamp >= startTimestamp + HARVEST_INTERVAL;
        }
        return block.timestamp >= user.nextHarvestUntil;
    }

    function updateStaking() public {
        uint256 multiplier = getMultiplier(lastRewardTimestamp);
        if (multiplier == 0) {
            return;
        }

        if (totalStaked == 0) {
            lastRewardTimestamp = block.timestamp;
            return;
        }

        uint256 tokenReward = multiplier * tokenPerDay;
        tokensForReward += tokenReward;

        accTokenPerShare += tokenReward * 1e12 / totalStaked;
        lastRewardTimestamp = block.timestamp;
    }

    function deposit(uint256 _amount) public {
        require(_amount >= minDeposit, "Not Enough Required Tokens!");
        UserInfo storage user = userInfo[msg.sender];
        updateStaking();
        payOrLockupPendingToken();
        if(_amount > 0) {
            // track balance before and after calling tranferFrom to incorporate tokens that charge a fee on transfer
            uint256 initialBalance = token.balanceOf(address(this));
            token.transferFrom(address(msg.sender), address(this), _amount);
            uint256 finalBalance = token.balanceOf(address(this));
            uint256 delta = finalBalance - initialBalance;
            totalStaked += delta;
            user.amount += delta;
        }
        user.rewardDebt = user.amount * accTokenPerShare / 1e12;
        emit Deposit(msg.sender, _amount);
    }

    function startWithdrawingProcess(uint256 _amount) public {
        WithdrawPending storage wp = withdrawPending[msg.sender];
        UserInfo storage user = userInfo[msg.sender];

        require(_amount > 0, 'Amount should be more than zero');
        require(user.amount >= _amount, "Insufficient amount");

        wp.reserved += _amount;
        wp.endOfPending = block.timestamp + withdrawPendingPeriod;

        updateStaking();
        payOrLockupPendingToken();

        totalStaked -= _amount;
        user.amount -= _amount;
        user.rewardDebt = user.amount * accTokenPerShare / 1e12;
        emit AddWithdrawPending(msg.sender, _amount);
    }

    function withdrawReserved() public {
        WithdrawPending storage wp = withdrawPending[msg.sender];
        require(wp.endOfPending <= block.timestamp, 'Wait until your pending period is left');
        token.transfer(address(msg.sender), wp.reserved);
        wp.reserved = 0;
        emit Withdraw(msg.sender, wp.reserved);
    }

    function getReward() public {
        updateStaking();
        payOrLockupPendingToken();
    }

    function payOrLockupPendingToken() internal {
        UserInfo storage user = userInfo[msg.sender];

        if (user.nextHarvestUntil == 0) {
            user.nextHarvestUntil = block.timestamp + HARVEST_INTERVAL;
        }

        uint256 pending = user.amount * accTokenPerShare / 1e12 - user.rewardDebt;
        if (canHarvest(msg.sender)) {
            if (pending > 0 || user.rewardLockedUp > 0) {
                uint256 totalRewards = pending + user.rewardLockedUp;

                // reset lockup
                totalLockedUpRewards -= user.rewardLockedUp;
                user.rewardLockedUp = 0;
                user.nextHarvestUntil = block.timestamp + HARVEST_INTERVAL;

                // send rewards
                token.transfer(msg.sender, totalRewards);
                totalPaid += totalRewards;
            }
        } else if (pending > 0) {
            user.rewardLockedUp += pending;
            totalLockedUpRewards += pending;
            emit RewardLockedUp(msg.sender, pending);
        }
    }
}