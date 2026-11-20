// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title LandFeeToken
 * @notice Closed-loop prepaid fee credit for the land registry (1.00 token = N1).
 *         - Minted/burned only by MINTER_ROLE (your backend, after a confirmed
 *           Paystack/Flutterwave payment or a refund).
 *         - Can only move to or from the treasury, so users cannot trade it.
 *         Written for OpenZeppelin Contracts v5.
 */
contract LandFeeToken is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    address public treasury;

    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    constructor(address admin, address minter, address treasury_) ERC20("Land Fee Credit", "LFEE") {
        require(
            admin != address(0) && minter != address(0) && treasury_ != address(0),
            "LandFeeToken: zero address"
        );
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, minter);
        treasury = treasury_;
    }

    /// 2 decimals so 1 unit = 1 kobo; 100 units = N1.
    function decimals() public pure override returns (uint8) {
        return 2;
    }

    /// Mint after the naira payment has been confirmed off-chain.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// Burn when credit is refunded to naira or expires.
    function burn(address from, uint256 amount) external onlyRole(MINTER_ROLE) {
        _burn(from, amount);
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTreasury != address(0), "LandFeeToken: zero treasury");
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// @dev Closed loop: mint and burn are fine; transfers must touch the treasury.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            require(
                to == treasury || from == treasury,
                "LandFeeToken: closed-loop transfers only"
            );
        }
        super._update(from, to, value);
    }
}
