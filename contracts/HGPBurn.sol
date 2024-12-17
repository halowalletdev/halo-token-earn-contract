// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./interfaces/IHaloWalletGenesisPass.sol";

contract HGPBurn {
    IHaloWalletGenesisPass public immutable HGP; // Address of HGP contract.

    event BatchBurn(address indexed user, uint256[] tokenIds);

    constructor(IHaloWalletGenesisPass HGP_) {
        HGP = HGP_;
    }

    // User should call `HGP.setApprovalForAll()` to approve this contract firstly
    function batchBurn(uint256[] calldata tokenIds) external {
        require(tokenIds.length > 0, "INV_ARG");
        uint256 id;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            id = tokenIds[i];
            require(HGP.ownerOf(id) == msg.sender, "NOT_OWNER");
            HGP.burn(id);
        }
        emit BatchBurn(msg.sender, tokenIds);
    }
}
