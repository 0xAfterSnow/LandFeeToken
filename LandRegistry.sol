// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {LandTitleNFT} from "./LandTitleNFT.sol";
import {LandFeeToken} from "./LandFeeToken.sol";

/**
 * @title LandRegistry
 * @notice Entry point for approved registrations and registry-controlled
 *         transfers. Called by the backend only AFTER spatial verification,
 *         ownership/oracle verification and registrar approval have passed.
 *         Fees (in LandFeeToken) are collected atomically with the action:
 *         if the payer has not approved/funded the fee, the whole tx reverts.
 */
contract LandRegistry is AccessControl {
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    enum FeeType {
        Registration,
        Transfer
    }

    LandTitleNFT public immutable nft;
    LandFeeToken public immutable feeToken;

    // Fee schedule in token units (2 decimals: 500000 = N5,000.00)
    mapping(FeeType => uint256) public fees;

    // Replay protection: each approved application can be executed once
    mapping(bytes32 => bool) public applicationProcessed;

    // Counters feeding "Table A - Smart Contract and NFT Lifecycle Events"
    uint256 public titlesIssued;
    uint256 public transfersCompleted;
    uint256 public totalFeesCollected;

    event RegistrationExecuted(
        bytes32 indexed applicationId,
        uint256 indexed tokenId,
        address indexed owner,
        uint256 timestamp
    );
    event TransferExecuted(
        bytes32 indexed applicationId,
        uint256 indexed tokenId,
        address indexed newOwner,
        uint256 timestamp
    );
    event FeeCollected(
        bytes32 indexed applicationId,
        address indexed payer,
        FeeType feeType,
        uint256 amount
    );
    event FeeUpdated(FeeType feeType, uint256 oldAmount, uint256 newAmount);

    constructor(
        address admin,
        LandTitleNFT nft_,
        LandFeeToken feeToken_,
        uint256 registrationFee,
        uint256 transferFee
    ) {
        require(
            admin != address(0) && address(nft_) != address(0) && address(feeToken_) != address(0),
            "LandRegistry: zero address"
        );
        nft = nft_;
        feeToken = feeToken_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        fees[FeeType.Registration] = registrationFee;
        fees[FeeType.Transfer] = transferFee;
    }

    // -------------------------------------------------------------------- fees

    function setFee(FeeType feeType, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit FeeUpdated(feeType, fees[feeType], amount);
        fees[feeType] = amount;
    }

    /// Pull the fee from `payer` to the treasury. Payer must have approved this contract.
    function _collectFee(bytes32 applicationId, address payer, FeeType feeType) internal {
        uint256 amount = fees[feeType];
        if (amount == 0) return;

        require(
            feeToken.transferFrom(payer, feeToken.treasury(), amount),
            "LandRegistry: fee payment failed"
        );
        totalFeesCollected += amount;
        emit FeeCollected(applicationId, payer, feeType, amount);
    }

    // ------------------------------------------------------------ registration

    /// Part A + B: validate rules, collect fee, record on-chain, mint the NFT title.
    /// The title owner pays the registration fee.
    function registerTitle(
        bytes32 applicationId,
        address owner,
        bytes32 parcelId,
        bytes32 spatialHash,
        string calldata uri
    ) external onlyRole(REGISTRAR_ROLE) returns (uint256 tokenId) {
        require(!applicationProcessed[applicationId], "LandRegistry: application already processed");
        require(owner != address(0), "LandRegistry: zero owner");
        require(parcelId != bytes32(0) && spatialHash != bytes32(0), "LandRegistry: empty hash");

        applicationProcessed[applicationId] = true;
        _collectFee(applicationId, owner, FeeType.Registration);

        tokenId = nft.mintTitle(owner, parcelId, spatialHash, applicationId, uri);
        titlesIssued++;

        emit RegistrationExecuted(applicationId, tokenId, owner, block.timestamp);
    }

    /// Registry-controlled ownership change (sale, inheritance, etc.).
    /// The incoming owner (newOwner) pays the transfer fee.
    function transferTitle(bytes32 applicationId, uint256 tokenId, address newOwner)
        external
        onlyRole(REGISTRAR_ROLE)
    {
        require(!applicationProcessed[applicationId], "LandRegistry: application already processed");
        require(!nft.isRevoked(tokenId), "LandRegistry: title revoked");
        require(newOwner != address(0), "LandRegistry: zero recipient");

        applicationProcessed[applicationId] = true;
        _collectFee(applicationId, newOwner, FeeType.Transfer);

        nft.registryTransfer(tokenId, newOwner);
        transfersCompleted++;

        emit TransferExecuted(applicationId, tokenId, newOwner, block.timestamp);
    }
}
