// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface EventsAndErrors {
    /*//////////////////////////////////////////////////////////////
                                 events
    //////////////////////////////////////////////////////////////*/
    event UpdatePool(
        uint256 lastRewardBlock,
        uint256 totalStaked,
        uint256 accHaloPerShare
    );
    event Staked(address indexed from, address indexed to, uint256 amount);
    event ClaimAndStaked(
        address indexed from,
        address indexed to,
        uint256 amount
    );
    event Cooldown(address indexed user, uint256 amount, uint256 startTime);
    event Redeem(address indexed from, address indexed to, uint256 amount);
    event RewardsClaimed(
        address indexed from,
        address indexed to,
        uint256 amount
    );
    event RewardVaultChanged(address newVault);
    event RewardRateChanged(uint256 amount);
    event CooldownSecondsChanged(uint256 cooldownSeconds);
    event UnstakeSecondsChanged(uint256 unstakeSeconds);

    /*//////////////////////////////////////////////////////////////
                                 errors
    //////////////////////////////////////////////////////////////*/
}
