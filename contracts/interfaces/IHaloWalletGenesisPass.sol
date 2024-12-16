// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IHaloWalletGenesisPass is IERC721 {
    function burn(uint256 tokenId) external;
}
