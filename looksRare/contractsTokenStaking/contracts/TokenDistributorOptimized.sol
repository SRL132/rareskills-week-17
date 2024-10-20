// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILooksRareToken} from "./interfaces/ILooksRareToken.sol";

/**
 * @title TokenDistributor
 * @notice It handles the distribution of LOOKS token.
 * It auto-adjusts block rewards over a set number of periods.
 */
//@audit make sure the optimizer is high enough when deploying since this contract may be used a lot
contract TokenDistributorOptimized is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for ILooksRareToken;

    struct StakingPeriod {
        uint256 rewardPerBlockForStaking;
        uint256 rewardPerBlockForOthers;
        uint256 periodLengthInBlock;
    }

    struct UserInfo {
        uint256 amount; // Amount of staked tokens provided by user
        uint256 rewardDebt; // Reward debt
    }

    // Precision factor for calculating rewards
    //q byteshifting instead of ** ? DONE: byteshifting result is not precise enough
    uint256 public constant PRECISION_FACTOR = 10 ** 12;

    ILooksRareToken public immutable i_looksRareToken;

    address public immutable i_tokenSplitter;

    // Number of reward periods
    uint256 public immutable i_numberPeriods;

    // Block number when rewards start
    uint256 public immutable i_startBlock;

    //@audit the following variables could be packed in order to save gas
    // Accumulated tokens per share
    uint256 public s_accTokenPerShare;

    // Current phase for rewards
    uint256 public s_currentPhase;

    // Block number when rewards end
    uint256 public s_endBlock;

    // Block number of the last update
    uint256 public s_lastRewardBlock;

    // Tokens distributed per block for other purposes (team + treasury + trading rewards)
    uint256 public s_rewardPerBlockForOthers;

    // Tokens distributed per block for staking
    uint256 public s_rewardPerBlockForStaking;
    //----until s_rewardPerBlockForStaking could be packed
    // Total amount staked
    uint256 public s_totalAmountStaked;

    mapping(uint256 => StakingPeriod) public s_stakingPeriod;

    mapping(address => UserInfo) public s_userInfo;

    event Compound(address indexed user, uint256 harvestedAmount);
    event Deposit(address indexed user, uint256 amount, uint256 harvestedAmount);
    event NewRewardsPerBlock(
        uint256 indexed currentPhase,
        uint256 startBlock,
        uint256 rewardPerBlockForStaking,
        uint256 rewardPerBlockForOthers
    );
    event Withdraw(address indexed user, uint256 amount, uint256 harvestedAmount);

    /**
     * @notice Constructor
     * @param _looksRareToken LOOKS token address
     * @param _tokenSplitter token splitter contract address (for team and trading rewards)
     * @param _startBlock start block for reward program
     * @param _rewardsPerBlockForStaking array of rewards per block for staking
     * @param _rewardsPerBlockForOthers array of rewards per block for other purposes (team + treasury + trading rewards)
     * @param _periodLengthesInBlocks array of period lengthes
     * @param _numberPeriods number of periods with different rewards/lengthes (e.g., if 3 changes --> 4 periods)
     */
    constructor(
        address _looksRareToken,
        address _tokenSplitter,
        uint256 _startBlock,
        uint256[] memory _rewardsPerBlockForStaking,
        uint256[] memory _rewardsPerBlockForOthers,
        uint256[] memory _periodLengthesInBlocks,
        uint256 _numberPeriods
    ) {
        //@audit use custom error to save gas
        //@audit-2 do it in assembly
        //@audit-3 short-circuit the require with ors
        // if( (_periodLengthesInBlocks.length != _numberPeriods) ||
        //  (_rewardsPerBlockForStaking.length != _numberPeriods) ||
        //  (_rewardsPerBlockForStaking.length != _numberPeriods){
        //       TokenDistributor__InvalidLengthes();
        //    }
        require(
            (_periodLengthesInBlocks.length == _numberPeriods) &&
                (_rewardsPerBlockForStaking.length == _numberPeriods) &&
                (_rewardsPerBlockForStaking.length == _numberPeriods),
            "Distributor: Lengthes must match numberPeriods"
        );

        // 1. Operational checks for supply
        uint256 nonCirculatingSupply = ILooksRareToken(_looksRareToken).SUPPLY_CAP() -
            ILooksRareToken(_looksRareToken).totalSupply();

        uint256 amountTokensToBeMinted;
        //@audit ++i
        //@audit-2 use do while to save gas
        //@audit-3 use unchecked for i increment
        /*   uint256 i = 0;
        do {
            amountTokensToBeMinted +=
                (_rewardsPerBlockForStaking[i] * _periodLengthesInBlocks[i]) +
                (_rewardsPerBlockForOthers[i] * _periodLengthesInBlocks[i]);

            s_stakingPeriod[i] = StakingPeriod({
                rewardPerBlockForStaking: _rewardsPerBlockForStaking[i],
                rewardPerBlockForOthers: _rewardsPerBlockForOthers[i],
                periodLengthInBlock: _periodLengthesInBlocks[i]
            });
            unchecked {
                ++i;
            }
        } while (i < _numberPeriods);
*/
        for (uint256 i = 0; i < _numberPeriods; i++) {
            amountTokensToBeMinted +=
                (_rewardsPerBlockForStaking[i] * _periodLengthesInBlocks[i]) +
                (_rewardsPerBlockForOthers[i] * _periodLengthesInBlocks[i]);

            s_stakingPeriod[i] = StakingPeriod({
                rewardPerBlockForStaking: _rewardsPerBlockForStaking[i],
                rewardPerBlockForOthers: _rewardsPerBlockForOthers[i],
                periodLengthInBlock: _periodLengthesInBlocks[i]
            });
        }
        //@audit use custom error to save gas
        //@audit-2 do the if and the revert in assembly
        //     assembly {
        //          if iszero(eq(amountTokensToBeMinted, nonCirculatingSupply)) {
        //             //tokenDistributor__InvalidRewardParameters()
        //              let freeMemoryPtr := mload(0x40)
        //              mstore(freeMemoryPtr, 0xfecf6a)
        //
        //             revert(freeMemoryPtr, 0x04)
        //         }
        //     }
        require(amountTokensToBeMinted == nonCirculatingSupply, "Distributor: Wrong reward parameters");

        // 2. Store values
        i_looksRareToken = ILooksRareToken(_looksRareToken);
        i_tokenSplitter = _tokenSplitter;
        s_rewardPerBlockForStaking = _rewardsPerBlockForStaking[0];
        s_rewardPerBlockForOthers = _rewardsPerBlockForOthers[0];

        i_startBlock = _startBlock;
        s_endBlock = _startBlock + _periodLengthesInBlocks[0];

        i_numberPeriods = _numberPeriods;

        // Set the s_lastRewardBlock as the startBlock
        s_lastRewardBlock = _startBlock;
    }

    /**
     * @notice Deposit staked tokens and compounds pending rewards
     * @param amount amount to deposit (in LOOKS)
     */
    function deposit(uint256 amount) external nonReentrant {
        //@audit use custom error to save gas
        //@audit-2 do the check and revert in assembly
        /*       assembly {
            if eq(amount, 0) {
                //TokenDistributor__InvalidAmount()
                let freeMemoryPtr := mload(0x40)
                mstore(freeMemoryPtr, 0xb381c3be)
                revert(freeMemoryPtr, 0x04)
            }
        }
        */
        require(amount > 0, "Deposit: Amount must be > 0");

        // Update pool information
        _updatePool();

        // Transfer LOOKS tokens to this contract
        i_looksRareToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 pendingRewards;

        // If not new deposit, calculate pending rewards (for auto-compounding)
        if (s_userInfo[msg.sender].amount > 0) {
            pendingRewards =
                ((s_userInfo[msg.sender].amount * s_accTokenPerShare) / PRECISION_FACTOR) -
                s_userInfo[msg.sender].rewardDebt;
        }

        // Adjust user information
        s_userInfo[msg.sender].amount += (amount + pendingRewards);
        s_userInfo[msg.sender].rewardDebt = (s_userInfo[msg.sender].amount * s_accTokenPerShare) / PRECISION_FACTOR;

        // Increase s_totalAmountStaked
        s_totalAmountStaked += (amount + pendingRewards);

        emit Deposit(msg.sender, amount, pendingRewards);
    }

    /**
     * @notice Compound based on pending rewards
     */
    function harvestAndCompound() external nonReentrant {
        // Update pool information
        _updatePool();

        // Calculate pending rewards
        uint256 pendingRewards = ((s_userInfo[msg.sender].amount * s_accTokenPerShare) / PRECISION_FACTOR) -
            s_userInfo[msg.sender].rewardDebt;

        // Return if no pending rewards
        //@audit this simple check and return can be done in assembly
        /*     assembly {
            if eq(pendingRewards, 0) {
                return(0, 0)
            }
        }
            */
        if (pendingRewards == 0) {
            // It doesn't throw revertion (to help with the fee-sharing auto-compounding contract)
            return;
        }

        // Adjust user amount for pending rewards
        //@audit can use unchecked block here to save gas
        /*     unchecked {
            s_userInfo[msg.sender].amount += pendingRewards;
        }
        */
        // Adjust s_totalAmountStaked
        //q can this block be unchecked to save gas?
        s_totalAmountStaked += pendingRewards;

        // Recalculate reward debt based on new user amount
        s_userInfo[msg.sender].rewardDebt = (s_userInfo[msg.sender].amount * s_accTokenPerShare) / PRECISION_FACTOR;

        emit Compound(msg.sender, pendingRewards);
    }

    /**
     * @notice Update pool rewards
     */
    function updatePool() external nonReentrant {
        _updatePool();
    }

    /**
     * @notice Withdraw staked tokens and compound pending rewards
     * @param amount amount to withdraw
     */
    function withdraw(uint256 amount) external nonReentrant {
        //@audit use custom error to save gas
        //@audit-2 do the check and revert in assembly
        //@audit-3 split the require into multiple require statements to save gas
        //@audit-4 use invert s_userInfo[msg.sender].amount >= amount logic
        /*    if (s_userInfo[msg.sender].amount < amount || (amount == 0)) {
            assembly {
                //TokenDistributor__InvalidAmount()
                let freeMemoryPtr := mload(0x40)
                mstore(freeMemoryPtr, 0xb381c3be)
                revert(freeMemoryPtr, 0x04)
            }
        }
            */
        require(
            (s_userInfo[msg.sender].amount >= amount) && (amount > 0),
            "Withdraw: Amount must be > 0 or lower than user balance"
        );

        // Update pool
        _updatePool();

        // Calculate pending rewards
        uint256 pendingRewards = ((s_userInfo[msg.sender].amount * s_accTokenPerShare) / PRECISION_FACTOR) -
            s_userInfo[msg.sender].rewardDebt;

        // Adjust user information
        s_userInfo[msg.sender].amount = s_userInfo[msg.sender].amount + pendingRewards - amount;
        s_userInfo[msg.sender].rewardDebt = (s_userInfo[msg.sender].amount * s_accTokenPerShare) / PRECISION_FACTOR;

        // Adjust total amount staked
        s_totalAmountStaked = s_totalAmountStaked + pendingRewards - amount;

        // Transfer LOOKS tokens to the sender
        i_looksRareToken.safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount, pendingRewards);
    }

    /**
     * @notice Withdraw all staked tokens and collect tokens
     */
    function withdrawAll() external nonReentrant {
        //@audit use custom error to save gas
        //@audit-2 do the check and revert in assembly
        /*   if (s_userInfo[msg.sender].amount == 0) {
            assembly {
                //TokenDistributor__InvalidAmount()
                let freeMemoryPtr := mload(0x40)
                mstore(freeMemoryPtr, 0xb381c3be)
                revert(freeMemoryPtr, 0x04)
            }
        }
        */
        require(s_userInfo[msg.sender].amount > 0, "Withdraw: Amount must be > 0");

        // Update pool
        _updatePool();

        // Calculate pending rewards and amount to transfer (to the sender)
        uint256 pendingRewards = ((s_userInfo[msg.sender].amount * s_accTokenPerShare) / PRECISION_FACTOR) -
            s_userInfo[msg.sender].rewardDebt;
        //q can unchecked be used here? DONE: cannot be used because its scope would be isolated
        uint256 amountToTransfer = s_userInfo[msg.sender].amount + pendingRewards;

        // Adjust total amount staked
        s_totalAmountStaked = s_totalAmountStaked - s_userInfo[msg.sender].amount;

        // Adjust user information
        s_userInfo[msg.sender].amount = 0;
        s_userInfo[msg.sender].rewardDebt = 0;

        // Transfer LOOKS tokens to the sender
        i_looksRareToken.safeTransfer(msg.sender, amountToTransfer);

        emit Withdraw(msg.sender, amountToTransfer, pendingRewards);
    }

    /**
     * @notice Calculate pending rewards for a user
     * @param user address of the user
     * @return Pending rewards
     */
    function calculatePendingRewards(address user) external view returns (uint256) {
        if ((block.number > s_lastRewardBlock) && (s_totalAmountStaked != 0)) {
            uint256 multiplier = _getMultiplier(s_lastRewardBlock, block.number);

            uint256 tokenRewardForStaking = multiplier * s_rewardPerBlockForStaking;

            uint256 adjustedEndBlock = s_endBlock;
            uint256 adjustedCurrentPhase = s_currentPhase;

            // Check whether to adjust multipliers and reward per block
            while ((block.number > adjustedEndBlock) && (adjustedCurrentPhase < (i_numberPeriods - 1))) {
                // Update current phase
                //q can unchecked be used here?
                /*        unchecked {
                    ++adjustedCurrentPhase;
                }
                */
                adjustedCurrentPhase++;

                // Update rewards per block
                uint256 adjustedRewardPerBlockForStaking = s_stakingPeriod[adjustedCurrentPhase]
                    .rewardPerBlockForStaking;

                // Calculate adjusted block number
                uint256 previousEndBlock = adjustedEndBlock;

                // Update end block
                //q can unchecked be used here?
                /*    unchecked {
                    adjustedEndBlock =
                        previousEndBlock +
                        s_stakingPeriod[adjustedCurrentPhase]
                            .periodLengthInBlock;
                }
                */
                adjustedEndBlock = previousEndBlock + s_stakingPeriod[adjustedCurrentPhase].periodLengthInBlock;

                // Calculate new multiplier
                //@audit use assembly block for the ternary and strict equality
                //            Unoptimized
                //function max(uint256 x, uint256 y) public pure returns (uint256 z) {
                //    z = x > y ? x : y;
                //}

                //Optimized
                //function max(uint256 x, uint256 y) public pure returns (uint256 z) {
                /// @solidity memory-safe-assembly
                //   assembly {
                //        z := xor(x, mul(xor(x, y), gt(y, x)))
                //   }
                //}
                //make sure it is safe for (block.number - previousEndBlock)

                /*
                uint256 newMultiplier = (block.number > adjustedEndBlock)
                    ? s_stakingPeriod[adjustedCurrentPhase].periodLengthInBlock; 
                    : (block.number - previousEndBlock)
                */

                uint256 newMultiplier = (block.number <= adjustedEndBlock)
                    ? (block.number - previousEndBlock)
                    : s_stakingPeriod[adjustedCurrentPhase].periodLengthInBlock;

                // Adjust token rewards for staking
                tokenRewardForStaking += (newMultiplier * adjustedRewardPerBlockForStaking);
            }
            uint256 adjustedTokenPerShare = s_accTokenPerShare +
                (tokenRewardForStaking * PRECISION_FACTOR) /
                s_totalAmountStaked;
            return (s_userInfo[user].amount * adjustedTokenPerShare) / PRECISION_FACTOR - s_userInfo[user].rewardDebt;
        } else {
            return (s_userInfo[user].amount * s_accTokenPerShare) / PRECISION_FACTOR - s_userInfo[user].rewardDebt;
        }
    }

    /**
     * @notice Update reward variables of the pool
     */
    function _updatePool() internal {
        //q can use assembly for these checks? can avoid non-strict comparison?
        //  if (s_lastRewardBlock > block.number) {
        //       return;
        //   }
        /*
        assembly {
            let lastRewardBlock := sload(3)
            if gt(lastRewardBlock, number()) {
                return(0, 0)
            }
        }
        */
        if (block.number <= s_lastRewardBlock) {
            return;
        }
        /*
        assembly {
            let totalAmountStaked := sload(6)

            if eq(totalAmountStaked, 0) {
                sstore(3, number())
                return(0, 0)
            }
        }
        */
        if (s_totalAmountStaked == 0) {
            s_lastRewardBlock = block.number;
            return;
        }

        // Calculate multiplier
        uint256 multiplier = _getMultiplier(s_lastRewardBlock, block.number);

        // Calculate rewards for staking and others
        uint256 tokenRewardForStaking = multiplier * s_rewardPerBlockForStaking;
        uint256 tokenRewardForOthers = multiplier * s_rewardPerBlockForOthers;

        // Check whether to adjust multipliers and reward per block
        while ((block.number > s_endBlock) && (s_currentPhase < (i_numberPeriods - 1))) {
            // Update rewards per block
            _updateRewardsPerBlock(s_endBlock);

            uint256 previousEndBlock = s_endBlock;

            // Adjust the end block
            //q can unchecked be used here?
            /*
            unchecked {
                s_endBlock += s_stakingPeriod[s_currentPhase]
                    .periodLengthInBlock;
            }
            */
            s_endBlock += s_stakingPeriod[s_currentPhase].periodLengthInBlock;

            // Adjust multiplier to cover the missing periods with other lower inflation schedule
            uint256 newMultiplier = _getMultiplier(previousEndBlock, block.number);

            // Adjust token rewards
            tokenRewardForStaking += (newMultiplier * s_rewardPerBlockForStaking);
            tokenRewardForOthers += (newMultiplier * s_rewardPerBlockForOthers);
        }

        // Mint tokens only if token rewards for staking are not null
        if (tokenRewardForStaking > 0) {
            // It allows protection against potential issues to prevent funds from being locked
            bool mintStatus = i_looksRareToken.mint(address(this), tokenRewardForStaking);
            if (mintStatus) {
                s_accTokenPerShare =
                    s_accTokenPerShare +
                    ((tokenRewardForStaking * PRECISION_FACTOR) / s_totalAmountStaked);
            }

            i_looksRareToken.mint(i_tokenSplitter, tokenRewardForOthers);
        }

        // Update last reward block only if it wasn't updated after or at the end block
        //q can non-stric comparison be used here?
        //q can assembly be used here?
        /*
        if (s_endBlock > s_lastRewardBlock) {
            s_lastRewardBlock = block.number;
        }

        assembly {
            let lastRewardBlock := sload(3)
            let endBlock := sload(5)

            if gt(endBlock, lastRewardBlock) {
                sstore(3, number())
            }
        }
        */

        if (s_lastRewardBlock <= s_endBlock) {
            s_lastRewardBlock = block.number;
        }
    }

    /**
     * @notice Update rewards per block
     * @dev Rewards are halved by 2 (for staking + others)
     */
    function _updateRewardsPerBlock(uint256 _newStartBlock) internal {
        // Update current phase
        //q can unchecked be used here?
        //can ++s_currentPhase be used here?
        //   unchecked {
        //      s_currentPhase++;
        //   }
        s_currentPhase++;

        // Update rewards per block
        s_rewardPerBlockForStaking = s_stakingPeriod[s_currentPhase].rewardPerBlockForStaking;
        s_rewardPerBlockForOthers = s_stakingPeriod[s_currentPhase].rewardPerBlockForOthers;

        emit NewRewardsPerBlock(s_currentPhase, _newStartBlock, s_rewardPerBlockForStaking, s_rewardPerBlockForOthers);
    }

    /**
     * @notice Return reward multiplier over the given "from" to "to" block.
     * @param from block to start calculating reward
     * @param to block to finish calculating reward
     * @return the multiplier for the period
     */
    //@audit use named return to save gas
    function _getMultiplier(
        uint256 from,
        uint256 to
    )
        internal
        view
        returns (
            //uint256 result
            uint256
        )
    {
        //@use strict comparison
        //@use assembly
        //   //   if (s_endBlock > to) {
        //    return to - from;
        //     } else if (s_endBlock < from) {
        //         return 0;
        //    } else {
        //        return s_endBlock - from;
        //    }

        if (to <= s_endBlock) {
            return to - from;
        } else if (from >= s_endBlock) {
            return 0;
        } else {
            return s_endBlock - from;
        }
    }
}
