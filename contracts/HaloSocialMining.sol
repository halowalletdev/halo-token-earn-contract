// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract HaloSocialMining is Ownable2Step, ReentrancyGuard {
    struct ClaimParams {
        uint256 sessionId;
        uint256 amount; // reward amount
        bytes32[] proof; // user's merkle proof
    }
    IERC20 public immutable HALO;
    address public rewardVault; // vault address to pay tokens
    mapping(uint256 sessionId => bytes32) public sessionMerkleRoot;
    mapping(address user => mapping(uint256 sessionId => bool))
        public isClaimed;

    event SessionRewardClaimed(uint256 sessionId, address user, uint256 amount);
    event RewardVaultChanged(address newVault);
    event SessionSet(uint256 sessionId, bytes32 root);

    constructor(
        address owner_,
        IERC20 HALO_,
        address rewardVault_
    ) Ownable(owner_) {
        HALO = HALO_;
        rewardVault = rewardVault_;
    }

    function claimSessionRewards(
        ClaimParams[] calldata params
    ) external nonReentrant {
        uint256 len = params.length;
        require(len > 0, "INV_PARAM");
        uint256 sessionId;
        uint256 amount;
        bytes32[] calldata proof;
        for (uint256 i = 0; i < len; i++) {
            // get param
            sessionId = params[i].sessionId;
            amount = params[i].amount;
            proof = params[i].proof;
            // verify parameters
            require(sessionMerkleRoot[sessionId] != 0x0, "NOT_START");
            require(proof.length > 0 && amount > 0, "INV_PARAM");
            require(!isClaimed[msg.sender][sessionId], "HAS_CLAIMED");
            // merkle verify
            bytes32 leaf = keccak256(abi.encode(msg.sender, amount));
            require(
                MerkleProof.verify(proof, sessionMerkleRoot[sessionId], leaf),
                "INV_PROOF"
            );
            // mark it claimed
            isClaimed[msg.sender][sessionId] = true;
            // transfer: vault -> user
            SafeERC20.safeTransferFrom(
                IERC20(HALO),
                rewardVault,
                msg.sender,
                amount
            );
            // event
            emit SessionRewardClaimed(sessionId, msg.sender, amount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        owner's functions
    //////////////////////////////////////////////////////////////*/

    function setSessionMerkleRoot(
        uint256 sessionId,
        bytes32 sessionRoot
    ) external onlyOwner {
        sessionMerkleRoot[sessionId] = sessionRoot;
        emit SessionSet(sessionId, sessionRoot);
    }

    function updateRewardVault(address newVault) external onlyOwner {
        rewardVault = newVault;
        emit RewardVaultChanged(rewardVault);
    }

    function emergencyWithdraw(
        address receiver,
        uint256 amount
    ) external onlyOwner {
        payable(receiver).transfer(amount);
    }

    function emergencyWithdrawERC20(
        address token,
        address receiver,
        uint256 amount
    ) external onlyOwner {
        SafeERC20.safeTransfer(IERC20(token), receiver, amount);
    }
}
