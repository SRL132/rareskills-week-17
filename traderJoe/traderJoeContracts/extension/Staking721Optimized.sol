// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

/// @author thirdweb

import "../external-deps/openzeppelin/security/ReentrancyGuard.sol";
import "../external-deps/openzeppelin/utils/math/SafeMath.sol";
import "../eip/interface/IERC721.sol";

import "./interface/IStaking721.sol";

abstract contract Staking721Optimized is ReentrancyGuard, IStaking721 {
    /*///////////////////////////////////////////////////////////////
                            State variables / Mappings
    //////////////////////////////////////////////////////////////*/

    ///@dev Address of ERC721 NFT contract -- staked tokens belong to this contract.
    address public immutable i_stakingToken;
    //q should isStaking and nextConditionId be larger?
    /// @dev Flag to check direct transfers of staking tokens.
    //q should isStaking be a bool?
    uint8 internal s_isStaking = 1;

    ///@dev Next staking condition Id. Tracks number of conditon updates so far.
    //@audit make conditionId larger uint248 s_nextConditionId;
    uint64 private s_nextConditionId;

    ///@dev List of token-ids ever staked.
    uint256[] public s_indexedTokens;

    /// @dev List of accounts that have staked their NFTs.
    address[] public s_stakersArray;

    ///@dev Mapping from token-id to whether it is indexed or not.
    mapping(uint256 => bool) public s_isIndexed;

    ///@dev Mapping from staker address to Staker struct. See {struct IStaking721.Staker}.
    mapping(address => Staker) public s_stakers;

    /// @dev Mapping from staked token-id to staker address.
    mapping(uint256 => address) public s_stakerAddress;

    ///@dev Mapping from condition Id to staking condition. See {struct IStaking721.StakingCondition}
    mapping(uint256 => StakingCondition) private s_stakingConditions;

    constructor(address _stakingToken) ReentrancyGuard() {
        //@audit use custom error
        //@audit use assembly
        require(address(_stakingToken) != address(0), "collection address 0");
        i_stakingToken = _stakingToken;
    }

    /*///////////////////////////////////////////////////////////////
                        External/Public Functions
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice    Stake ERC721 Tokens.
     *
     *  @dev       See {_stake}. Override that to implement custom logic.
     *
     *  @param _tokenIds    List of tokens to stake.
     */
    //@q should we get rid of this function and just make _stake public?
    function stake(uint256[] calldata _tokenIds) external nonReentrant {
        _stake(_tokenIds);
    }

    /**
     *  @notice    Withdraw staked tokens.
     *
     *  @dev       See {_withdraw}. Override that to implement custom logic.
     *
     *  @param _tokenIds    List of tokens to withdraw.
     */
    //@q should we get rid of this function and just make _withdraw public?
    function withdraw(uint256[] calldata _tokenIds) external nonReentrant {
        _withdraw(_tokenIds);
    }

    /**
     *  @notice    Claim accumulated rewards.
     *
     *  @dev       See {_claimRewards}. Override that to implement custom logic.
     *             See {_calculateRewards} for reward-calculation logic.
     */
    //@q should we get rid of this function and just make _claimRewards public?
    function claimRewards() external nonReentrant {
        _claimRewards();
    }

    /**
     *  @notice  Set time unit. Set as a number of seconds.
     *           Could be specified as -- x * 1 hours, x * 1 days, etc.
     *
     *  @dev     Only admin/authorized-account can call it.
     *
     *
     *  @param _timeUnit    New time unit.
     */
    function setTimeUnit(uint256 _timeUnit) external virtual {
        if (!_canSetStakeConditions()) {
            //@audit use custom error
            //@audit use assembly
            revert("Not authorized");
        }
        //@q why is StakingCondition passed to memory?
        StakingCondition memory condition = s_stakingConditions[s_nextConditionId - 1];
        //@audit use custom error
        //@audit use assembly
        require(_timeUnit != condition.timeUnit, "Time-unit unchanged.");

        _setStakingCondition(_timeUnit, condition.rewardsPerUnitTime);

        emit UpdatedTimeUnit(condition.timeUnit, _timeUnit);
    }

    /**
     *  @notice  Set rewards per unit of time.
     *           Interpreted as x rewards per second/per day/etc based on time-unit.
     *
     *  @dev     Only admin/authorized-account can call it.
     *
     *
     *  @param _rewardsPerUnitTime    New rewards per unit time.
     */
    function setRewardsPerUnitTime(uint256 _rewardsPerUnitTime) external virtual {
        //@audit use custom error
        //@audit use assembly
        if (!_canSetStakeConditions()) {
            revert("Not authorized");
        }
        //@q why is StakingCondition passed to memory?
        StakingCondition memory condition = s_stakingConditions[s_nextConditionId - 1];
        //@audit use custom error
        //@audit use assembly
        require(_rewardsPerUnitTime != condition.rewardsPerUnitTime, "Reward unchanged.");

        _setStakingCondition(condition.timeUnit, _rewardsPerUnitTime);

        emit UpdatedRewardsPerUnitTime(condition.rewardsPerUnitTime, _rewardsPerUnitTime);
    }

    /**
     *  @notice View amount staked and total rewards for a user.
     *
     *  @param _staker          Address for which to calculated rewards.
     *  @return _tokensStaked   List of token-ids staked by staker.
     *  @return _rewards        Available reward amount.
     */
    function getStakeInfo(
        address _staker
    ) external view virtual returns (uint256[] memory _tokensStaked, uint256 _rewards) {
        uint256[] memory _indexedTokens = s_indexedTokens;
        bool[] memory _isStakerToken = new bool[](_indexedTokens.length);
        uint256 indexedTokenCount = _indexedTokens.length;
        uint256 stakerTokenCount = 0;

        //@use do while with unchecked increment
        for (uint256 i = 0; i < indexedTokenCount; i++) {
            _isStakerToken[i] = s_stakerAddress[_indexedTokens[i]] == _staker;
            //@audit use unchecked increment
            if (_isStakerToken[i]) stakerTokenCount += 1;
        }

        _tokensStaked = new uint256[](stakerTokenCount);
        uint256 count = 0;
        //@use do while with unchecked increment
        for (uint256 i = 0; i < indexedTokenCount; i++) {
            if (_isStakerToken[i]) {
                _tokensStaked[count] = _indexedTokens[i];
                //@audit use unchecked increment
                count += 1;
            }
        }

        _rewards = _availableRewards(_staker);
    }

    function getTimeUnit() public view returns (uint256 _timeUnit) {
        _timeUnit = s_stakingConditions[s_nextConditionId - 1].timeUnit;
    }

    function getRewardsPerUnitTime() public view returns (uint256 _rewardsPerUnitTime) {
        _rewardsPerUnitTime = s_stakingConditions[s_nextConditionId - 1].rewardsPerUnitTime;
    }

    /*///////////////////////////////////////////////////////////////
                            Internal Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Staking logic. Override to add custom logic.
    function _stake(uint256[] calldata _tokenIds) internal virtual {
        uint64 len = uint64(_tokenIds.length);
        //@audit use custom error
        //@audit use assembly
        require(len != 0, "Staking 0 tokens");
        //@audit is this worth it? can t we just call the immutable variable directly?
        address _stakingToken = i_stakingToken;

        if (s_stakers[_stakeMsgSender()].amountStaked > 0) {
            _updateUnclaimedRewardsForStaker(_stakeMsgSender());
        } else {
            s_stakersArray.push(_stakeMsgSender());
            s_stakers[_stakeMsgSender()].timeOfLastUpdate = uint128(block.timestamp);
            s_stakers[_stakeMsgSender()].conditionIdOflastUpdate = s_nextConditionId - 1;
        }
        //@audit use unchecked increment
        //@use do while
        for (uint256 i = 0; i < len; ++i) {
            //@audit why is it changing s_isStaking here to 2? and what is this variable used for?
            //suggestion -->change isStaking logic to a bool or 1 and 0
            s_isStaking = 2;
            IERC721(_stakingToken).safeTransferFrom(_stakeMsgSender(), address(this), _tokenIds[i]);
            s_isStaking = 1;

            s_stakerAddress[_tokenIds[i]] = _stakeMsgSender();

            if (!s_isIndexed[_tokenIds[i]]) {
                s_isIndexed[_tokenIds[i]] = true;
                s_indexedTokens.push(_tokenIds[i]);
            }
        }
        //@audit use unchecked increment
        s_stakers[_stakeMsgSender()].amountStaked += len;

        emit TokensStaked(_stakeMsgSender(), _tokenIds);
    }

    /// @dev Withdraw logic. Override to add custom logic.
    function _withdraw(uint256[] calldata _tokenIds) internal virtual {
        uint256 _amountStaked = s_stakers[_stakeMsgSender()].amountStaked;
        uint64 len = uint64(_tokenIds.length);
        //@audit use custom error
        //@audit use assembly
        require(len != 0, "Withdrawing 0 tokens");
        //@audit use strict comparison
        require(_amountStaked >= len, "Withdrawing more than staked");

        address _stakingToken = i_stakingToken;

        _updateUnclaimedRewardsForStaker(_stakeMsgSender());

        if (_amountStaked == len) {
            //q can t we use a mapping instead?
            address[] memory _stakersArray = s_stakersArray;
            //@audit use do while
            //@audit use unchecked increment
            for (uint256 i = 0; i < _stakersArray.length; ++i) {
                if (_stakersArray[i] == _stakeMsgSender()) {
                    s_stakersArray[i] = _stakersArray[_stakersArray.length - 1];
                    s_stakersArray.pop();
                    break;
                }
            }
        }
        s_stakers[_stakeMsgSender()].amountStaked -= len;
        //@audit use do while
        //@audit use unchecked increment
        for (uint256 i = 0; i < len; ++i) {
            //@audit use custom error
            //@audit use assembly
            require(s_stakerAddress[_tokenIds[i]] == _stakeMsgSender(), "Not staker");
            s_stakerAddress[_tokenIds[i]] = address(0);
            IERC721(_stakingToken).safeTransferFrom(address(this), _stakeMsgSender(), _tokenIds[i]);
        }

        emit TokensWithdrawn(_stakeMsgSender(), _tokenIds);
    }

    /// @dev Logic for claiming rewards. Override to add custom logic.
    function _claimRewards() internal virtual {
        //q can this be unchecked?
        uint256 rewards = s_stakers[_stakeMsgSender()].unclaimedRewards + _calculateRewards(_stakeMsgSender());
        //@audit use custom error
        //@audit use assembly
        require(rewards != 0, "No rewards");

        s_stakers[_stakeMsgSender()].timeOfLastUpdate = uint128(block.timestamp);
        s_stakers[_stakeMsgSender()].unclaimedRewards = 0;
        s_stakers[_stakeMsgSender()].conditionIdOflastUpdate = s_nextConditionId - 1;

        _mintRewards(_stakeMsgSender(), rewards);

        emit RewardsClaimed(_stakeMsgSender(), rewards);
    }

    /// @dev View available rewards for a user.
    function _availableRewards(address _user) internal view virtual returns (uint256 _rewards) {
        //@audit use assembly with xor
        if (s_stakers[_user].amountStaked == 0) {
            _rewards = s_stakers[_user].unclaimedRewards;
        } else {
            //@q can this be unchecked?
            _rewards = s_stakers[_user].unclaimedRewards + _calculateRewards(_user);
        }
    }

    /// @dev Update unclaimed rewards for a users. Called for every state change for a user.
    function _updateUnclaimedRewardsForStaker(address _staker) internal virtual {
        uint256 rewards = _calculateRewards(_staker);
        //@audit can this be unchecked?
        s_stakers[_staker].unclaimedRewards += rewards;
        s_stakers[_staker].timeOfLastUpdate = uint128(block.timestamp);
        s_stakers[_staker].conditionIdOflastUpdate = s_nextConditionId - 1;
    }

    /// @dev Set staking conditions.
    function _setStakingCondition(uint256 _timeUnit, uint256 _rewardsPerUnitTime) internal virtual {
        //@audit use custom error
        //@audit use assembly
        require(_timeUnit != 0, "time-unit can't be 0");
        uint256 conditionId = s_nextConditionId;
        //@audit use unchecked increment
        s_nextConditionId += 1;
        //@audit use packing for struct variables
        s_stakingConditions[conditionId] = StakingCondition({
            timeUnit: _timeUnit,
            rewardsPerUnitTime: _rewardsPerUnitTime,
            startTimestamp: block.timestamp,
            endTimestamp: 0
        });

        if (conditionId > 0) {
            s_stakingConditions[conditionId - 1].endTimestamp = block.timestamp;
        }
    }

    /// @dev Calculate rewards for a staker.
    function _calculateRewards(address _staker) internal view virtual returns (uint256 _rewards) {
        Staker memory staker = s_stakers[_staker];

        uint256 _stakerConditionId = staker.conditionIdOflastUpdate;
        //q is this conditionId scaleable?
        uint256 _nextConditionId = s_nextConditionId;
        //@audit use do while
        //@audit use unchecked increment
        for (uint256 i = _stakerConditionId; i < _nextConditionId; i += 1) {
            StakingCondition memory condition = s_stakingConditions[i];
            //@assembly use xor condition
            uint256 startTime = i != _stakerConditionId ? condition.startTimestamp : staker.timeOfLastUpdate;
            //@assembly use xor condition
            uint256 endTime = condition.endTimestamp != 0 ? condition.endTimestamp : block.timestamp;
            //@audit is safeMath redundant here?
            (bool noOverflowProduct, uint256 rewardsProduct) = SafeMath.tryMul(
                (endTime - startTime) * staker.amountStaked,
                condition.rewardsPerUnitTime
            );
            //@audit is safeMath redundant here?
            (bool noOverflowSum, uint256 rewardsSum) = SafeMath.tryAdd(_rewards, rewardsProduct / condition.timeUnit);
            //@audit use xor condition in assembly
            _rewards = noOverflowProduct && noOverflowSum ? rewardsSum : _rewards;
        }
    }

    /*////////////////////////////////////////////////////////////////////
        Optional hooks that can be implemented in the derived contract
    ///////////////////////////////////////////////////////////////////*/

    /// @dev Exposes the ability to override the msg sender -- support ERC2771.
    function _stakeMsgSender() internal virtual returns (address) {
        return msg.sender;
    }

    /*///////////////////////////////////////////////////////////////
        Virtual functions to be implemented in derived contract
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice View total rewards available in the staking contract.
     *
     */
    function getRewardTokenBalance() external view virtual returns (uint256 _rewardsAvailableInContract);

    /**
     *  @dev    Mint/Transfer ERC20 rewards to the staker. Must override.
     *
     *  @param _staker    Address for which to calculated rewards.
     *  @param _rewards   Amount of tokens to be given out as reward.
     *
     *  For example, override as below to mint ERC20 rewards:
     *
     * ```
     *  function _mintRewards(address _staker, uint256 _rewards) internal override {
     *
     *      TokenERC20(rewardTokenAddress).mintTo(_staker, _rewards);
     *
     *  }
     * ```
     */
    function _mintRewards(address _staker, uint256 _rewards) internal virtual;

    /**
     *  @dev    Returns whether staking restrictions can be set in given execution context.
     *          Must override.
     *
     *
     *  For example, override as below to restrict access to admin:
     *
     * ```
     *  function _canSetStakeConditions() internal override {
     *
     *      return msg.sender == adminAddress;
     *
     *  }
     * ```
     */
    function _canSetStakeConditions() internal view virtual returns (bool);
}
