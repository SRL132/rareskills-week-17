// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/SafeERC20.sol";
import "./libraries/SafeMath.sol";

/**
 * @title TokenVesting
 * @dev A token holder contract that can release its token balance gradually like a
 * typical vesting scheme, with a cliff and vesting period. Optionally revocable by the
 * owner.
 */
contract TokenVestingOptimized is Ownable {
    // The vesting schedule is time-based (i.e. using block timestamps as opposed to e.g. block numbers), and is
    // therefore sensitive to timestamp manipulation (which is something miners can do, to a certain degree). Therefore,
    // it is recommended to avoid using short time durations (less than a minute). Typical vesting schemes, with a
    // cliff period of a year and a duration of four years, are safe to use.
    // solhint-disable not-rely-on-time

    //  using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event TokensReleased(address token, uint256 amount);
    event TokenVestingRevoked(address token);

    // beneficiary of tokens after they are released
    //@audit change to immutable
    address private immutable i_beneficiary;

    // Durations and timestamps are expressed in UNIX time, the same units as block.timestamp.
    //@audit change to immutable
    //q can immutable variables get packed?
    uint256 private immutable i_cliff;
    uint256 private immutable i_start;
    uint256 private immutable i_duration;

    bool private immutable i_revocable;

    mapping(address => uint256) private s_released;
    mapping(address => bool) private s_revoked;

    /**
     * @dev Creates a vesting contract that vests its balance of any ERC20 token to the
     * beneficiary, gradually in a linear fashion until start + duration. By then all
     * of the balance will have vested.
     * @param beneficiary address of the beneficiary to whom vested tokens are transferred
     * @param cliffDuration duration in seconds of the cliff in which tokens will begin to vest
     * @param start the time (as Unix time) at which point vesting starts
     * @param duration duration in seconds of the period in which the tokens will vest
     * @param revocable whether the vesting is revocable or not
     */
    constructor(address beneficiary, uint256 start, uint256 cliffDuration, uint256 duration, bool revocable) public {
        //@audit custom error
        //@audit use assembly
        require(beneficiary != address(0), "TokenVesting: beneficiary is the zero address");
        // solhint-disable-next-line max-line-length
        //@audit custom error
        //@audit use assembly
        require(cliffDuration <= duration, "TokenVesting: cliff is longer than duration");
        require(duration > 0, "TokenVesting: duration is 0");
        // solhint-disable-next-line max-line-length
        //@audit custom error
        //@audit use assembly
        require(start + duration > block.timestamp, "TokenVesting: final time is before current time");

        i_beneficiary = beneficiary;
        i_revocable = revocable;
        i_duration = duration;
        i_cliff = start + cliffDuration;
        i_start = start;
    }

    /**
     * @return the beneficiary of the tokens.
     */
    function beneficiary() public view returns (address) {
        return i_beneficiary;
    }

    /**
     * @return the cliff time of the token vesting.
     */
    function cliff() public view returns (uint256) {
        return i_cliff;
    }

    /**
     * @return the start time of the token vesting.
     */
    function start() public view returns (uint256) {
        return i_start;
    }

    /**
     * @return the duration of the token vesting.
     */
    function duration() public view returns (uint256) {
        return i_duration;
    }

    /**
     * @return true if the vesting is revocable.
     */
    function revocable() public view returns (bool) {
        return i_revocable;
    }

    /**
     * @return the amount of the token released.
     */
    function released(address token) public view returns (uint256) {
        return s_released[token];
    }

    /**
     * @return true if the token is revoked.
     */
    function revoked(address token) public view returns (bool) {
        return s_revoked[token];
    }

    /**
     * @notice Transfers vested tokens to beneficiary.
     * @param token ERC20 token which is being vested
     */
    function release(IERC20 token) public {
        uint256 unreleased = _releasableAmount(token);
        //@audit custom error
        //@audit use assembly
        require(unreleased > 0, "TokenVesting: no tokens are due");
        //@audit can this be unchecked?
        s_released[address(token)] = s_released[address(token)] + unreleased;

        token.safeTransfer(i_beneficiary, unreleased);

        emit TokensReleased(address(token), unreleased);
    }

    /**
     * @notice Allows the owner to revoke the vesting. Tokens already vested
     * remain in the contract, the rest are returned to the owner.
     * @param token ERC20 token which is being vested
     */
    function revoke(IERC20 token) public onlyOwner {
        //@audit custom error
        //@audit use assembly
        require(i_revocable, "TokenVesting: cannot revoke");
        require(!s_revoked[address(token)], "TokenVesting: token already revoked");

        uint256 balance = token.balanceOf(address(this));

        uint256 unreleased = _releasableAmount(token);
        uint256 refund = balance - unreleased;

        s_revoked[address(token)] = true;

        token.safeTransfer(owner(), refund);

        emit TokenVestingRevoked(address(token));
    }

    /**
     * @notice Allows owner to emergency revoke and refund entire balance,
     * including the vested amount. To be used when beneficiary cannot claim
     * anymore, e.g. when he/she has lots its private key.
     * @param token ERC20 which is being vested
     */
    function emergencyRevoke(IERC20 token) public onlyOwner {
        //@audit custom error
        //@audit use assembly
        require(i_revocable, "TokenVesting: cannot revoke");
        require(!s_revoked[address(token)], "TokenVesting: token already revoked");

        uint256 balance = token.balanceOf(address(this));

        s_revoked[address(token)] = true;

        token.safeTransfer(owner(), balance);

        emit TokenVestingRevoked(address(token));
    }

    /**
     * @dev Calculates the amount that has already vested but hasn't been released yet.
     * @param token ERC20 token which is being vested
     */
    function _releasableAmount(IERC20 token) private view returns (uint256) {
        return _vestedAmount(token) - s_released[address(token)];
    }

    /**
     * @dev Calculates the amount that has already vested.
     * @param token ERC20 token which is being vested
     */
    //@q named return?
    function _vestedAmount(IERC20 token) private view returns (uint256) {
        uint256 currentBalance = token.balanceOf(address(this));
        uint256 totalBalance = currentBalance + s_released[address(token)];

        if (block.timestamp < i_cliff) {
            return 0;
            //@audit change strict inequality
        } else if (block.timestamp >= i_start + i_duration || s_revoked[address(token)]) {
            return totalBalance;
        } else {
            return (totalBalance * (block.timestamp - i_start)) / i_duration;
        }
    }
}
