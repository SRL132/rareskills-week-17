// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

//import "openzeppelin-solidity-2.3.0/contracts/token/ERC20/ERC20Detailed.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

// Inheritance
import {IStakingRewards} from "./interfaces/IStakingRewards.sol";
import {RewardsDistributionRecipient} from "./RewardsDistributionRecipient.sol";
import {Pausable} from "./Pausable.sol";
import {Owned} from "./Owned.sol";

// https://docs.synthetix.io/contracts/source/contracts/stakingrewards
//q confirm best possible
contract StakingRewards is
    IStakingRewards,
    RewardsDistributionRecipient,
    ReentrancyGuard,
    Pausable
{
    //    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */
    //@audit change variables to immutable
    IERC20 public immutable i_rewardsToken;
    IERC20 public immutable i_stakingToken;
    //q can periodFinish and lastUpdateTime be packed?
    uint256 public s_periodFinish = 0;
    //q can rewardRate and rewardsDuration be packed?
    uint256 public s_rewardRate = 0;
    uint256 public s_rewardsDuration = 7 days;
    uint256 public s_lastUpdateTime;
    //q can rewardPerTokenStored be packed with rewardRate?
    uint256 public s_rewardPerTokenStored;

    mapping(address => uint256) public s_userRewardPerTokenPaid;
    mapping(address => uint256) public s_rewards;

    uint256 private s_totalSupply;
    mapping(address => uint256) private s_balances;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _owner,
        address _rewardsDistribution,
        address _rewardsToken,
        address _stakingToken //Owned(_owner)
    ) RewardsDistributionRecipient(_owner) {
        i_rewardsToken = IERC20(_rewardsToken);
        i_stakingToken = IERC20(_stakingToken);
        s_rewardsDistribution = _rewardsDistribution;
    }

    /* ========== VIEWS ========== */

    function totalSupply() external view returns (uint256) {
        return s_totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return s_balances[account];
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        //@audit use assembly to optimize
        //      assembly {
        //          lastTimeReward := xor(
        //             s_periodFinish,
        //             mul(
        //                 xor(s_periodFinish, block.timestamp),
        //                 lt(block.timestamp, s_periodFinish)
        //            )
        //         )
        //     }
        return
            block.timestamp < s_periodFinish ? block.timestamp : s_periodFinish;
    }

    //q use named returns?
    //q use assembly to control memory expansion costs? https://www.rareskills.io/post/gas-optimization#viewer-95r43
    function rewardPerToken() public view returns (uint256) {
        if (s_totalSupply == 0) {
            return s_rewardPerTokenStored;
        }
        return
            s_rewardPerTokenStored +
            lastTimeRewardApplicable() -
            //add byteshifting s_rewardRate << 60 ??
            (s_lastUpdateTime * s_rewardRate * 1e18) /
            s_totalSupply;
    }

    function earned(address account) public view returns (uint256) {
        return
            (s_balances[account] *
                (rewardPerToken() - s_userRewardPerTokenPaid[account])) /
            //add byteshifting s_rewardRate >> 60 ??
            1e18 +
            s_rewards[account];
    }

    function getRewardForDuration() external view returns (uint256) {
        //@audit uncheck since can not be overflowed
        unchecked {
            return s_rewardRate * s_rewardsDuration;
        }
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(
        uint256 amount
    ) external nonReentrant notPaused updateReward(msg.sender) {
        //@audit add custom errors
        //@audit-2 do it in assembly
        //     assembly {
        //         let freeMemoryPointer := mload(0x40)
        //         mstore(freeMemoryPointer, 0x705f0317)  -->hash for CANNOT_STAKE_ZERO()
        //         revert(0x40, 0x04)
        //     }
        require(amount > 0, "Cannot stake 0");
        //@audit uncheck since can not be overflowed
        unchecked {
            s_totalSupply = s_totalSupply + amount;
            s_balances[msg.sender] = s_balances[msg.sender] + amount;
        }
        i_stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(
        uint256 amount
    ) public nonReentrant updateReward(msg.sender) {
        //@audit add custom errors
        //@audit-2 do it in assembly
        //     assembly {
        //         let freeMemoryPointer := mload(0x40)
        //         mstore(freeMemoryPointer, 0x705f0317)  -->hash for CANNOT_WITHDRAW_MORE_THAN_BALANCE()
        require(amount > 0, "Cannot withdraw 0");
        s_totalSupply = s_totalSupply - amount;
        s_balances[msg.sender] = s_balances[msg.sender] - amount;
        i_stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }
    //@q set function as view?
    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = s_rewards[msg.sender];
        if (reward > 0) {
            s_rewards[msg.sender] = 0;
            i_rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external {
        withdraw(s_balances[msg.sender]);
        getReward();
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function notifyRewardAmount(
        uint256 reward
    ) external override onlyRewardsDistribution updateReward(address(0)) {
        //@audit invert order with strict comparison
        //    if (block.timestamp < s_periodFinish) {
        //        uint256 remaining = s_periodFinish - block.timestamp;
        //         uint256 leftover = remaining * s_rewardRate;
        //         s_rewardRate = reward + leftover / s_rewardsDuration;
        //     } else {
        //         s_rewardRate = reward / s_rewardsDuration;
        //     }

        //original
        if (block.timestamp >= s_periodFinish) {
            //@audit add unchecked block
            unchecked {
                s_rewardRate = reward / s_rewardsDuration;
            }
        } else {
            //@audit add unchecked block
            unchecked {
                uint256 remaining = s_periodFinish - block.timestamp;
                uint256 leftover = remaining * s_rewardRate;
                s_rewardRate = reward + leftover / s_rewardsDuration;
            }
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of s_rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint256 balance = i_rewardsToken.balanceOf(address(this));
        //@audit add custom errors
        //@audit-2 do it in assembly
        //     assembly {
        //         let freeMemoryPointer := mload(0x40)
        //         mstore(freeMemoryPointer, 0x705f0317)  -->hash for PROVIDED_REWARD_TOO_HIGH()
        //         revert(0x40, 0x04)
        require(
            s_rewardRate <= balance / s_rewardsDuration,
            "Provided reward too high"
        );

        s_lastUpdateTime = block.timestamp;
        //@audit add unchecked block
        unchecked {
            s_periodFinish = block.timestamp + s_rewardsDuration;
        }
        emit RewardAdded(reward);
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(
        address tokenAddress,
        uint256 tokenAmount
    ) external onlyOwner {
        //@audit add custom errors
        //@audit-2 do it in assembly
        //  assembly {
        //  let freeMemoryPointer := mload(0x40)
        //       mstore(freeMemoryPointer, 0x705f0317)  -->hash for CANNOT_WITHDRAW_STAKING_TOKEN()
        //       revert(0x40, 0x04)
        //   }
        require(
            tokenAddress != address(i_stakingToken),
            "Cannot withdraw the staking token"
        );
        IERC20(tokenAddress).safeTransfer(owner, tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        //@audit add custom errors
        //@audit-2 do it in assembly
        //     assembly {
        //         let freeMemoryPointer := mload(0x40)
        //          mstore(freeMemoryPointer, 0x705f0317)  -->hash for CANNOT_SET_REWARDS_DURATION()
        //         revert(0x40, 0x04)
        //      }
        require(
            block.timestamp > s_periodFinish,
            "Previous s_rewards period must be complete before changing the duration for the new period"
        );
        s_rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(s_rewardsDuration);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        s_rewardPerTokenStored = rewardPerToken();
        s_lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            s_rewards[account] = earned(account);
            s_userRewardPerTokenPaid[account] = s_rewardPerTokenStored;
        }
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
}
