// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract HaloAirdrop is Ownable2Step, ReentrancyGuard, Pausable {
    struct AirdropDetail {
        bytes32 root; // the merkle root for airdrop whitelist. leaf node=address+amount
        uint256 imdClaimPct; // 0~100. the percentage of tokens that can be claimed immediately
        uint256 totalUnlockPhases; // indicates how many stages are required to unlock all tokens
    }
    struct UserLockInfo {
        uint256 lockStartAt;
        uint256 totalAmount; // the total amount locked at the beginning
        uint256 claimedAmount; // unlocked and claimed amount
    }
    uint256 public constant AIRDROP_FOR_MP = 1;
    uint256 public constant AIRDROP_FOR_GP = 2;
    uint256 public constant DURATION_PER_PHASE = 30 * 24 * 60 * 60; // 30days
    //
    IERC20 public immutable HALO; // address of HALO token contract.
    address public treasury; // accept the token of the penalty part
    uint256 public claimStartAt;
    AirdropDetail public airdropMP;
    AirdropDetail public airdropGP;
    mapping(address user => bool) public isClaimedMP;
    mapping(address user => bool) public isClaimedGP;

    mapping(address user => UserLockInfo) public userInfoMP;
    mapping(address user => UserLockInfo) public userInfoGP;
    // for badge creators
    mapping(address influencer => uint256 amount) public influencerClaimableAmt;

    event ClaimOnlyForMP(
        address claimer,
        uint256 toUserAmount,
        uint256 toTreasuryAmount
    );
    event ClaimAndLock(
        address claimer,
        uint256 claimAmount,
        uint256 lockAmount,
        uint256 airdropType
    );
    event ClaimAsInfluencer(address claimer, uint256 claimAmount);
    event Unlock(address unlocker, uint256 amount, uint256 airdropType);

    constructor(
        address owner_,
        IERC20 HALO_,
        address treasury_,
        uint256 claimStartAt_
    ) Ownable(owner_) {
        HALO = HALO_;
        treasury = treasury_;
        claimStartAt = claimStartAt_;
    }

    // HMP Holders: "just claim part" or "lock all"
    function claimOrLockForMP(
        bytes32[] calldata proof,
        uint256 amount,
        bool isLock // whether to lock all
    ) external nonReentrant whenNotPaused {
        // verify parameters
        require(
            block.timestamp > claimStartAt && airdropMP.root != 0x0,
            "NOT_START"
        );
        require(proof.length > 0 && amount > 0, "INV_PARAM");
        require(!isClaimedMP[msg.sender], "HAS_CLAIMED");
        // merkle verify
        bytes32 leaf = keccak256(abi.encode(msg.sender, amount));
        require(MerkleProof.verify(proof, airdropMP.root, leaf), "INV_PROOF");
        // mark it claimed
        isClaimedMP[msg.sender] = true;

        if (isLock) {
            // lock all
            userInfoMP[msg.sender] = UserLockInfo({
                lockStartAt: block.timestamp,
                totalAmount: amount,
                claimedAmount: 0
            });
            emit ClaimAndLock(msg.sender, 0, amount, AIRDROP_FOR_MP);
        } else {
            // just claim part
            uint256 toUserAmount = (amount * airdropMP.imdClaimPct) / 100;
            uint256 toTreasuryAmount = amount - toUserAmount;
            // transfer: address(this)-> 1. to user + 2. to treasury
            SafeERC20.safeTransfer(IERC20(HALO), msg.sender, toUserAmount);
            SafeERC20.safeTransfer(IERC20(HALO), treasury, toTreasuryAmount);
            // event
            emit ClaimOnlyForMP(msg.sender, toUserAmount, toTreasuryAmount);
        }
    }

    // HGP Holders: claim part + lock others
    function claimAndLockForGP(
        bytes32[] calldata proof,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        // verify parameters
        require(
            block.timestamp > claimStartAt && airdropGP.root != 0x0,
            "NOT_START"
        );
        require(proof.length > 0 && amount > 0, "INV_PARAM");
        require(!isClaimedGP[msg.sender], "HAS_CLAIMED");
        // merkle verify
        bytes32 leaf = keccak256(abi.encode(msg.sender, amount));
        require(MerkleProof.verify(proof, airdropGP.root, leaf), "INV_PROOF");
        // mark it claimed
        isClaimedGP[msg.sender] = true;

        // 1. claim part
        uint256 toUserAmount = (amount * airdropGP.imdClaimPct) / 100;
        SafeERC20.safeTransfer(IERC20(HALO), msg.sender, toUserAmount);
        // 2. lock others
        uint256 lockAmount = amount - toUserAmount;
        userInfoGP[msg.sender] = UserLockInfo({
            lockStartAt: block.timestamp,
            totalAmount: lockAmount,
            claimedAmount: 0
        });
        emit ClaimAndLock(msg.sender, toUserAmount, lockAmount, AIRDROP_FOR_GP);
    }

    // Badge Creators: claim all at once
    function claimAsInfluencer() external nonReentrant whenNotPaused {
        require(block.timestamp > claimStartAt, "NOT_START");
        uint256 claimableAmt = influencerClaimableAmt[msg.sender];
        if (claimableAmt > 0) {
            // mark it claimed
            influencerClaimableAmt[msg.sender] = 0;
            // transfer
            SafeERC20.safeTransfer(IERC20(HALO), msg.sender, claimableAmt);
            // event
            emit ClaimAsInfluencer(msg.sender, claimableAmt);
        }
    }

    // Claim unlockable tokens
    function unlock(
        bool isUnlockForMP,
        bool isUnlockForGP
    ) external nonReentrant whenNotPaused {
        require(isUnlockForMP || isUnlockForGP, "INV_PARAM");
        (
            uint256 unlockableAmtForMP,
            uint256 unlockableAmtForGP,
            ,

        ) = getUnlockInfo(msg.sender);
        if (isUnlockForMP && unlockableAmtForMP > 0) {
            // update
            userInfoMP[msg.sender].claimedAmount += unlockableAmtForMP;
            // transfer: address(this)-> user
            SafeERC20.safeTransfer(
                IERC20(HALO),
                msg.sender,
                unlockableAmtForMP
            );
            // event
            emit Unlock(msg.sender, unlockableAmtForMP, AIRDROP_FOR_MP);
        }
        if (isUnlockForGP && unlockableAmtForGP > 0) {
            // update
            userInfoGP[msg.sender].claimedAmount += unlockableAmtForGP;
            // transfer: address(this)-> user
            SafeERC20.safeTransfer(
                IERC20(HALO),
                msg.sender,
                unlockableAmtForGP
            );
            // event
            emit Unlock(msg.sender, unlockableAmtForGP, AIRDROP_FOR_GP);
        }
    }

    // Get the currently remaining unlockable amounts, and next unlock timestamp
    function getUnlockInfo(
        address user
    )
        public
        view
        returns (
            uint256 unlockableAmtForMP,
            uint256 unlockableAmtForGP,
            uint256 nextUnlockTimeForMP,
            uint256 nextUnlockTimeForGP
        )
    {
        // for hmp
        UserLockInfo memory userInfoForMP = userInfoMP[user];
        if (userInfoForMP.lockStartAt > 0) {
            // else: lockStartAt=0 ==> unlockableAmtForMP = 0, nextUnlockTimeForMP=0
            uint256 currentPhases = (block.timestamp -
                userInfoForMP.lockStartAt) / DURATION_PER_PHASE;
            uint256 maxUnlockPhases = Math.min(
                airdropMP.totalUnlockPhases,
                currentPhases
            );
            uint256 maxUnlockAmount = (maxUnlockPhases *
                userInfoForMP.totalAmount) / airdropMP.totalUnlockPhases;
            unlockableAmtForMP = maxUnlockAmount - userInfoForMP.claimedAmount;
            // next unlock time
            if (currentPhases < airdropMP.totalUnlockPhases) {
                nextUnlockTimeForMP =
                    userInfoForMP.lockStartAt +
                    (currentPhases + 1) *
                    DURATION_PER_PHASE;
            }
        }
        // for gp
        UserLockInfo memory userInfoForGP = userInfoGP[user];
        if (userInfoForGP.lockStartAt > 0) {
            uint256 currentPhases = (block.timestamp -
                userInfoForGP.lockStartAt) / DURATION_PER_PHASE;

            uint256 maxUnlockPhases = Math.min(
                airdropGP.totalUnlockPhases,
                currentPhases
            );
            uint256 maxUnlockAmount = (maxUnlockPhases *
                userInfoForGP.totalAmount) / airdropGP.totalUnlockPhases;
            unlockableAmtForGP = maxUnlockAmount - userInfoForGP.claimedAmount;
            // next unlock time
            if (currentPhases < airdropGP.totalUnlockPhases) {
                nextUnlockTimeForGP =
                    userInfoForGP.lockStartAt +
                    (currentPhases + 1) *
                    DURATION_PER_PHASE;
            }
        }
    }

    function isClaimedInfluencer(address user) public view returns (bool) {
        // influencerClaimableAmt[user]=0  ->  has claimed     -> return true
        // influencerClaimableAmt[user]>0  ->  has't claimed   -> return false
        return influencerClaimableAmt[user] == 0;
    }

    function isValid(
        bytes32 root,
        bytes32[] memory proof,
        address user,
        uint256 amount
    ) public pure returns (bool) {
        bytes32 leaf = keccak256(abi.encode(user, amount));
        return MerkleProof.verify(proof, root, leaf);
    }

    /*//////////////////////////////////////////////////////////////
                        owner's functions
    //////////////////////////////////////////////////////////////*/
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setInfluencerInfos(
        address[] calldata influencers,
        uint256[] calldata amounts
    ) external onlyOwner {
        address influencer;
        uint256 amount;
        for (uint256 i = 0; i < influencers.length; i++) {
            influencer = influencers[i];
            amount = amounts[i];
            influencerClaimableAmt[influencer] = amount;
        }
    }

    function setClaimStartAt(uint256 newStartAt) external onlyOwner {
        claimStartAt = newStartAt;
    }

    function setAirdropDetail(
        bytes32 root_,
        uint256 imdClaimPct_,
        uint256 totalUnlockPhases_,
        bool isMP
    ) external onlyOwner {
        if (isMP) {
            airdropMP.root = root_;
            airdropMP.imdClaimPct = imdClaimPct_;
            airdropMP.totalUnlockPhases = totalUnlockPhases_;
        } else {
            airdropGP.root = root_;
            airdropGP.imdClaimPct = imdClaimPct_;
            airdropGP.totalUnlockPhases = totalUnlockPhases_;
        }
    }

    function setTreasury(address newTreasury) external onlyOwner {
        treasury = newTreasury;
    }

    function approveERC20(
        address token,
        address spender,
        uint256 amount
    ) external onlyOwner {
        IERC20(token).approve(spender, amount);
    }

    // Emergency withdrawal of tokens locked in this contract
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
    ////////// internal and private functions //////////////////////////
}
