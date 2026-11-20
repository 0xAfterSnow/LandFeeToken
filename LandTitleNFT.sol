// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title LandTitleNFT
 * @notice ERC-721 land title. Owners CANNOT transfer or approve; only the
 *         LandRegistry (REGISTRY_ROLE) can mint/transfer. Only the Governor
 *         (GOVERNOR_ROLE) can revoke, per Land Use Act 1978, s.28.
 *         Written for OpenZeppelin Contracts v5.
 */
contract LandTitleNFT is ERC721, AccessControl {
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant REGISTRY_ROLE = keccak256("REGISTRY_ROLE");

    enum RevocationGround {
        OverridingPublicInterest,
        BreachOfStatutoryCondition
    }

    struct Title {
        bytes32 parcelId;      // keccak256 of the parcel identity (links to off-chain/GIS record)
        bytes32 spatialHash;   // hash of the verified polygon (not the geometry itself)
        bytes32 applicationId; // links the title to the approved application
        uint64 issuedAt;
        string uri;            // title metadata (IPFS/MinIO URL)
    }

    uint256 private _nextTokenId = 1;
    bool private _registryOp;

    mapping(uint256 => Title) public titles;
    mapping(bytes32 => uint256) public activeTokenOfParcel; // 0 = no active title
    mapping(uint256 => bool) public isRevoked;
    mapping(uint256 => RevocationGround) public revocationGround;
    mapping(uint256 => uint64) public revokedAt;

    event TitleIssued(
        uint256 indexed tokenId,
        bytes32 indexed parcelId,
        address indexed owner,
        bytes32 spatialHash,
        bytes32 applicationId,
        uint256 timestamp
    );
    event TitleTransferredByRegistry(
        uint256 indexed tokenId,
        address indexed from,
        address indexed to,
        uint256 timestamp
    );
    // Distinct, auditable revocation event (separate from issuance)
    event TitleRevoked(
        uint256 indexed tokenId,
        RevocationGround ground,
        address indexed revokedBy,
        uint256 timestamp
    );

    constructor(address admin, address governor) ERC721("Land Title", "LTITLE") {
        require(admin != address(0) && governor != address(0), "LandTitleNFT: zero address");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, governor); // use a multisig in production
    }

    // ---------------------------------------------------------------- issuance

    function mintTitle(
        address to,
        bytes32 parcelId,
        bytes32 spatialHash,
        bytes32 applicationId,
        string calldata uri
    ) external onlyRole(REGISTRY_ROLE) returns (uint256 tokenId) {
        require(to != address(0), "LandTitleNFT: zero owner");
        require(activeTokenOfParcel[parcelId] == 0, "LandTitleNFT: parcel already titled");

        tokenId = _nextTokenId++;
        titles[tokenId] = Title(parcelId, spatialHash, applicationId, uint64(block.timestamp), uri);
        activeTokenOfParcel[parcelId] = tokenId;

        _mint(to, tokenId); // _mint (not _safeMint) to avoid receiver callbacks
        emit TitleIssued(tokenId, parcelId, to, spatialHash, applicationId, block.timestamp);
    }

    // ------------------------------------------------- registry-only transfers

    function registryTransfer(uint256 tokenId, address to) external onlyRole(REGISTRY_ROLE) {
        require(to != address(0), "LandTitleNFT: zero recipient");
        address from = _requireOwned(tokenId);
        _registryOp = true;
        _update(to, tokenId, address(0)); // auth = 0 skips owner/approval check
        _registryOp = false;
        emit TitleTransferredByRegistry(tokenId, from, to, block.timestamp);
    }

    // -------------------------------------------------------------- revocation

    function revoke(uint256 tokenId, RevocationGround ground) external onlyRole(GOVERNOR_ROLE) {
        _requireOwned(tokenId); // reverts if token does not exist
        require(!isRevoked[tokenId], "LandTitleNFT: already revoked");

        isRevoked[tokenId] = true;
        revocationGround[tokenId] = ground;
        revokedAt[tokenId] = uint64(block.timestamp);
        // Free the parcel so the registry can lawfully re-issue it later
        delete activeTokenOfParcel[titles[tokenId].parcelId];

        emit TitleRevoked(tokenId, ground, msg.sender, block.timestamp);
    }

    // ---------------------------------------------------------- transfer lock

    /// @dev Every ownership change flows through _update in OZ v5.
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        address from = _ownerOf(tokenId);
        if (from != address(0)) {
            // transfer (or burn) of an existing token
            require(_registryOp, "LandTitleNFT: owner-initiated transfers disabled");
            require(!isRevoked[tokenId], "LandTitleNFT: token is revoked");
        }
        return super._update(to, tokenId, auth);
    }

    // Approvals are meaningless in a registry-controlled system
    function approve(address, uint256) public pure override {
        revert("LandTitleNFT: approvals disabled");
    }

    function setApprovalForAll(address, bool) public pure override {
        revert("LandTitleNFT: approvals disabled");
    }

    // -------------------------------------------------------------------- misc

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return titles[tokenId].uri;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
