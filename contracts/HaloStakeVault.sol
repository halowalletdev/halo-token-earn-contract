// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/EventsAndErrors.sol";

contract HaloStakeVault is Ownable2Step, ReentrancyGuard, EventsAndErrors {
    struct CooldownSnapshot {
        uint256 timestamp;
        uint256 amount;
    }
    struct UserInfo {
        uint256 amount; // stake amount of user
        uint256 rewardDebt;
    }
    struct PoolInfo {
        uint256 accHaloPerShare; // accumulated reward_tokens per share, times ACC_PRECISION
        uint256 lastRewardBlock; // last block number that reward_tokens distribution occurs
        uint256 totalStaked; // sum of all users' stake amount
    }
    uint256 public constant ACC_PRECISION = 1e18;
    IERC20 public immutable stakeToken;
    IERC20 public immutable rewardToken;
    uint256 public rewardRatePerBlock; // reward tokens per block(3 seconds) to reward to pools e.g. 4*1e18
    address public rewardVault; // vault address to pay rewards, need to approve contract in advance

    uint256 public cooldownSeconds; // cooldown period
    uint256 public unstakeSeconds; // redeemable period

    mapping(address => uint256) public rewardsToClaim;
    mapping(address => CooldownSnapshot) public stakersCooldowns;
    mapping(address userAddr => UserInfo) public userInfo;

    PoolInfo public poolInfo;

    /////////////////// constructor ///////////////////
    constructor(
        address owner_,
        IERC20 stakeToken_,
        IERC20 rewardToken_,
        uint256 cooldownSeconds_,
        uint256 unstakeSeconds_,
        uint256 rewardRatePerBlock_,
        address rewardVault_,
        uint256 startBlock // the block number when reward starts
    ) Ownable(owner_) {
        stakeToken = stakeToken_;
        rewardToken = rewardToken_;
        cooldownSeconds = cooldownSeconds_;
        unstakeSeconds = unstakeSeconds_;
        rewardRatePerBlock = rewardRatePerBlock_;
        rewardVault = rewardVault_;
        poolInfo = PoolInfo({
            accHaloPerShare: 0,
            lastRewardBlock: Math.max(startBlock, block.number),
            totalStaked: 0
        });
        // for restake( when stakeToken=rewardToken )
        rewardToken.approve(address(this), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        external functions
    //////////////////////////////////////////////////////////////*/

    // Stake tokens to get rewards. Msg.sender pay tokens to stake for user `to`
    function stake(address to, uint256 amount) external nonReentrant {
        _stake(msg.sender, to, amount);
    }

    // Claim staking rewards
    // to: receive rewards, if amount > actual rewards amount, means claim all
    function claimRewards(address to, uint256 amount) external nonReentrant {
        _claimRewards(msg.sender, to, amount);
    }

    // Msg.sender claim all rewards to stake for user `to`
    function claimRewardsAndStake(address to) external nonReentrant {
        require(rewardToken == stakeToken, "INV_TOKEN");
        uint256 amountToClaim = _claimRewards(
            msg.sender,
            address(this),
            type(uint256).max // all rewards
        );
        _stake(address(this), to, amountToClaim);
        emit ClaimAndStaked(msg.sender, to, amountToClaim);
    }

    function cooldown() external nonReentrant {
        UserInfo memory user = userInfo[msg.sender];
        require(user.amount > 0, "INV_BALANCE_TO_COOLDOWN");
        stakersCooldowns[msg.sender] = CooldownSnapshot({
            timestamp: block.timestamp,
            amount: user.amount
        });
        // event
        emit Cooldown(msg.sender, user.amount, block.timestamp);
    }

    // Msg.sender redeem staked token and transfer to user `to`
    // if amount>actual cooldown amount, e.g. type(uint256).max, means redeem all
    function redeem(address to, uint256 amount) external nonReentrant {
        _redeem(msg.sender, to, amount);
    }

    // Update reward variables for pool
    function updatePool() public {
        if (block.number <= poolInfo.lastRewardBlock) {
            return;
        }
        if (poolInfo.totalStaked > 0) {
            uint256 multiplier = block.number - poolInfo.lastRewardBlock;
            uint256 haloReward = multiplier * rewardRatePerBlock;
            poolInfo.accHaloPerShare += Math.mulDiv(
                haloReward,
                ACC_PRECISION,
                poolInfo.totalStaked
            );
        }
        poolInfo.lastRewardBlock = block.number;
        // event
        emit UpdatePool(
            poolInfo.lastRewardBlock,
            poolInfo.totalStaked,
            poolInfo.accHaloPerShare
        );
    }

    // Update reward variables for pool, recommended to call `updatePool()` firstly
    function updateUser(address user_) public {
        UserInfo storage user = userInfo[user_];
        // update user's pending rewards
        uint256 pending = 0;
        if (user.amount > 0) {
            pending =
                Math.mulDiv(
                    user.amount,
                    poolInfo.accHaloPerShare,
                    ACC_PRECISION
                ) -
                user.rewardDebt;
        }
        rewardsToClaim[user_] += pending;
        user.rewardDebt = Math.mulDiv(
            user.amount,
            poolInfo.accHaloPerShare,
            ACC_PRECISION
        );
    }

    /*//////////////////////////////////////////////////////////////
                        public view or pure functions
    //////////////////////////////////////////////////////////////*/

    function pendingReward(address user_) public view returns (uint256) {
        UserInfo memory user = userInfo[user_];
        uint256 accHaloPerShare = poolInfo.accHaloPerShare;
        uint256 totalStaked = poolInfo.totalStaked;

        if (block.number > poolInfo.lastRewardBlock && totalStaked != 0) {
            uint256 multiplier = block.number - poolInfo.lastRewardBlock;
            uint256 haloReward = multiplier * rewardRatePerBlock;
            accHaloPerShare += Math.mulDiv(
                haloReward,
                ACC_PRECISION,
                totalStaked
            );
        }
        uint256 pending = 0;
        if (user.amount > 0)
            pending =
                Math.mulDiv(user.amount, accHaloPerShare, ACC_PRECISION) -
                user.rewardDebt;

        return rewardsToClaim[user_] + pending;
    }

    /*//////////////////////////////////////////////////////////////
                        owner's functions
    //////////////////////////////////////////////////////////////*/

    function updateRewardRate(
        uint256 newRatePerBlock_,
        bool _withUpdate
    ) external onlyOwner {
        // whether check 0
        // require(newRatePerBlock_ > 0, "INV_RATE");
        if (_withUpdate) {
            updatePool();
        }
        rewardRatePerBlock = newRatePerBlock_;
        emit RewardRateChanged(newRatePerBlock_);
    }

    function updateRewardVault(address newVault) external onlyOwner {
        rewardVault = newVault;
        emit RewardVaultChanged(rewardVault);
    }

    function updateCooldownSeconds(
        uint256 cooldownSeconds_
    ) external onlyOwner {
        cooldownSeconds = cooldownSeconds_;
        emit CooldownSecondsChanged(cooldownSeconds);
    }

    function updateUnstakeSeconds(uint256 unstakeSeconds_) external onlyOwner {
        unstakeSeconds = unstakeSeconds_;
        emit UnstakeSecondsChanged(unstakeSeconds);
    }

    ////////// internal and private functions //////////////////////////
    function _stake(address from, address to, uint256 amount) internal {
        require(amount != 0, "INV_STAKE_AMT");
        updatePool();
        updateUser(to);
        UserInfo storage user = userInfo[to];
        // token transer: from ->this
        SafeERC20.safeTransferFrom(
            IERC20(stakeToken),
            from,
            address(this),
            amount
        );
        user.amount += amount;
        // update total staked amount
        poolInfo.totalStaked += amount;

        user.rewardDebt = Math.mulDiv(
            user.amount,
            poolInfo.accHaloPerShare,
            ACC_PRECISION
        );
        // event
        emit Staked(from, to, amount);
    }

    function _claimRewards(
        address from, // claim from
        address to, // receive rewards
        uint256 amount // type(uint256).max means reward all
    ) internal returns (uint256) {
        require(amount != 0, "INV_CLAIM_AMT");
        updatePool();
        updateUser(from);
        uint256 amountToClaim = Math.min(amount, rewardsToClaim[from]);
        require(amountToClaim != 0, "INV_ZERO_AMT");
        rewardsToClaim[from] -= amountToClaim;
        // rewards token: vault-> to
        SafeERC20.safeTransferFrom(
            IERC20(rewardToken),
            rewardVault,
            to,
            amountToClaim
        );
        // event
        emit RewardsClaimed(from, to, amountToClaim);
        // return the actual claim amount
        return amountToClaim;
    }

    function _redeem(address from, address to, uint256 amount) internal {
        require(amount != 0, "INV_REDEEM_AMT");
        updatePool();
        updateUser(from);
        //
        CooldownSnapshot memory snapshot = stakersCooldowns[from];
        UserInfo storage user = userInfo[from];
        require(snapshot.amount > 0 && snapshot.timestamp > 0, "NOT_COOLDOWN");
        // check time
        require(
            (block.timestamp >= snapshot.timestamp + cooldownSeconds) &&
                (block.timestamp <=
                    snapshot.timestamp + cooldownSeconds + unstakeSeconds),
            "NOT_IN_VALID_PERIOD"
        );
        uint256 maxRedeemable = Math.min(snapshot.amount, user.amount);
        require(maxRedeemable != 0, "INV_MAX_REDEEMABLE");
        uint256 amountToRedeem = Math.min(amount, maxRedeemable);
        // update
        stakersCooldowns[from].amount -= amountToRedeem;
        user.amount -= amountToRedeem;
        user.rewardDebt = Math.mulDiv(
            user.amount,
            poolInfo.accHaloPerShare,
            ACC_PRECISION
        );
        poolInfo.totalStaked -= amountToRedeem;
        // transer token: this -> to
        SafeERC20.safeTransfer(IERC20(stakeToken), to, amountToRedeem);
        emit Redeem(from, to, amountToRedeem);
    }
}
