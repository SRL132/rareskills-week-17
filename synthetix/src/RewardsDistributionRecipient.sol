// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Inheritance
import {Owned} from "./Owned.sol";

// https://docs.synthetix.io/contracts/source/contracts/rewardsdistributionrecipient
contract RewardsDistributionRecipient is Owned {
    address public s_rewardsDistribution;

    constructor(address _owner) Owned(_owner) {}

    function notifyRewardAmount(uint256 reward) external {}

    modifier onlyRewardsDistribution() {
        require(
            msg.sender == s_rewardsDistribution,
            "Caller is not RewardsDistribution contract"
        );
        _;
    }

    function setRewardsDistribution(
        address _rewardsDistribution
    ) external onlyOwner {
        s_rewardsDistribution = _rewardsDistribution;
    }
}
