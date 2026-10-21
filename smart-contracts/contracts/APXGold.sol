// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title APXGold (Compliance-Aware Precious Metal Token)
 * @author APAX Protocol
 * @notice On-chain representation of allocated physical gold stored in audited vaults.
 *         Each 1.0 APX-Gold token represents exactly 1 fine gram of 99.99% (24k) allocated gold.
 * @dev Combines ERC-20 standard liquidity with ERC-3643 inspired regulatory compliance gates:
 *      - Role-Based Access Control (RBAC) separating Admin, Minter, Burner, and KYC Officer roles.
 *      - Transfer restrictions enforcing bidirectional KYC / Whitelist approval.
 *      - Freeze mechanism for individual sanctioned/compromised addresses.
 *      - Circuit breaker (Pausable) for protocol-wide emergency stops.
 *      - Mint tied directly to physical vault deposits; Burn tied to physical gold redemption.
 */
contract APXGold is ERC20, ERC20Burnable, ERC20Pausable, AccessControl {

    // =========================================================================
    // ROLES DEFINITIONS
    // =========================================================================
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant KYC_MANAGER_ROLE = keccak256("KYC_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // =========================================================================
    // COMPLIANCE & IDENTITY STATE (ERC-3643 HYBRID)
    // =========================================================================
    /// @notice Tracks KYC / AML verification status of investor wallets
    mapping(address => bool) private _kycApproved;

    /// @notice Tracks frozen status of wallets subject to regulatory/court orders or theft
    mapping(address => bool) private _frozen;

    // =========================================================================
    // AUDIT & VAULT METADATA
    // =========================================================================
    string public vaultLocation;
    string public constant METAL_TYPE = "Gold (Au) 99.99% Purity";

    // =========================================================================
    // CUSTOM ERRORS (Gas-Efficient)
    // =========================================================================
    error SenderNotKYCApproved(address sender);
    error RecipientNotKYCApproved(address recipient);
    error AccountFrozen(address account);
    error ZeroAddressNotAllowed();
    error ZeroAmountNotAllowed();
    error EmptyReceiptIdentifier();

    // =========================================================================
    // EVENTS
    // =========================================================================
    event KYCStatusUpdated(address indexed account, bool indexed status, address indexed operator);
    event AccountFreezeUpdated(address indexed account, bool indexed isFrozen, address indexed operator);
    event VaultDepositMinted(
        address indexed recipient,
        uint256 amount,
        string vaultBarSerialNumber,
        string auditProofRef
    );
    event PhysicalRedemptionBurnt(
        address indexed holder,
        uint256 amount,
        string deliveryOrderRef
    );
    event VaultLocationUpdated(string newLocation, address indexed operator);

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================
    /**
     * @notice Initializes the APX-Gold token and sets up multi-role governance.
     * @param admin The address holding super-admin rights to configure roles.
     * @param initialVaultLocation The physical vault location string (e.g. "Zurich, Switzerland - Vault A").
     */
    constructor(
        address admin,
        string memory initialVaultLocation
    ) ERC20("APAX Gold Token", "APX-GOLD") {
        if (admin == address(0)) revert ZeroAddressNotAllowed();

        vaultLocation = initialVaultLocation;

        // Setup role hierarchy and initial assignments
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(BURNER_ROLE, admin);
        _grantRole(KYC_MANAGER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);

        // Pre-approve the admin wallet for operational setup
        _kycApproved[admin] = true;
        emit KYCStatusUpdated(admin, true, msg.sender);
    }

    // =========================================================================
    // COMPLIANCE & KYC MANAGEMENT
    // =========================================================================
    /**
     * @notice Updates the KYC verification status of a single investor wallet.
     * @param account The wallet address to update.
     * @param status True to approve for transfers, false to revoke.
     */
    function setKYCStatus(address account, bool status) external onlyRole(KYC_MANAGER_ROLE) {
        if (account == address(0)) revert ZeroAddressNotAllowed();
        _kycApproved[account] = status;
        emit KYCStatusUpdated(account, status, msg.sender);
    }

    /**
     * @notice Batch updates KYC verification for multiple accounts to save gas.
     * @param accounts Array of wallet addresses.
     * @param status Approval status to set for all provided accounts.
     */
    function batchSetKYCStatus(
        address[] calldata accounts,
        bool status
    ) external onlyRole(KYC_MANAGER_ROLE) {
        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] == address(0)) revert ZeroAddressNotAllowed();
            _kycApproved[accounts[i]] = status;
            emit KYCStatusUpdated(accounts[i], status, msg.sender);
        }
    }

    /**
     * @notice Freezes or unfreezes an account in response to sanctions or security alerts.
     * @param account The address to freeze or unfreeze.
     * @param frozenStatus True to freeze, false to unfreeze.
     */
    function setAccountFreeze(address account, bool frozenStatus) external onlyRole(KYC_MANAGER_ROLE) {
        if (account == address(0)) revert ZeroAddressNotAllowed();
        _frozen[account] = frozenStatus;
        emit AccountFreezeUpdated(account, frozenStatus, msg.sender);
    }

    /**
     * @notice Checks if an address is KYC approved.
     * @param account Address to query.
     * @return True if approved, false otherwise.
     */
    function isKYCApproved(address account) external view returns (bool) {
        return _kycApproved[account];
    }

    /**
     * @notice Checks if an address is frozen.
     * @param account Address to query.
     * @return True if frozen, false otherwise.
     */
    function isFrozen(address account) external view returns (bool) {
        return _frozen[account];
    }

    // =========================================================================
    // VAULT-BACKED MINTING & BURNING
    // =========================================================================
    /**
     * @notice Mints new APX-Gold tokens strictly upon physical gold deposit verification.
     * @param recipient The KYC-approved wallet receiving the minted tokens.
     * @param amount The amount of tokens to mint (in 18 decimals, 1 token = 1 gram).
     * @param vaultBarSerialNumber Serial number or barcode of the physical gold bar added to vault.
     * @param auditProofRef Reference identifier / IPFS hash of third-party audit report.
     */
    function mintWithVaultProof(
        address recipient,
        uint256 amount,
        string calldata vaultBarSerialNumber,
        string calldata auditProofRef
    ) external onlyRole(MINTER_ROLE) whenNotPaused {
        if (recipient == address(0)) revert ZeroAddressNotAllowed();
        if (amount == 0) revert ZeroAmountNotAllowed();
        if (bytes(vaultBarSerialNumber).length == 0) revert EmptyReceiptIdentifier();
        if (!_kycApproved[recipient]) revert RecipientNotKYCApproved(recipient);
        if (_frozen[recipient]) revert AccountFrozen(recipient);

        _mint(recipient, amount);

        emit VaultDepositMinted(recipient, amount, vaultBarSerialNumber, auditProofRef);
    }

    /**
     * @notice Burns tokens as part of the physical gold redemption workflow.
     * @dev Called by BURNER_ROLE once physical delivery is officially processed and confirmed.
     * @param from The holder address redeeming physical gold.
     * @param amount Amount of tokens being burned (equivalent grams of physical gold).
     * @param deliveryOrderRef Reference tracking number of the logistics/delivery manifest.
     */
    function burnForRedemption(
        address from,
        uint256 amount,
        string calldata deliveryOrderRef
    ) external onlyRole(BURNER_ROLE) whenNotPaused {
        if (from == address(0)) revert ZeroAddressNotAllowed();
        if (amount == 0) revert ZeroAmountNotAllowed();
        if (bytes(deliveryOrderRef).length == 0) revert EmptyReceiptIdentifier();

        _burn(from, amount);

        emit PhysicalRedemptionBurnt(from, amount, deliveryOrderRef);
    }

    // =========================================================================
    // EMERGENCY CIRCUIT BREAKER (PAUSABLE)
    // =========================================================================
    /**
     * @notice Pauses all token transfers in emergency situations.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Resumes token transfers once emergency is resolved.
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Updates the registered vault facility metadata.
     * @param newLocation Description/address of new vault facility.
     */
    function updateVaultLocation(string calldata newLocation) external onlyRole(DEFAULT_ADMIN_ROLE) {
        vaultLocation = newLocation;
        emit VaultLocationUpdated(newLocation, msg.sender);
    }

    // =========================================================================
    // INTERNAL COMPLIANCE ENFORCEMENT HOOK
    // =========================================================================
    /**
     * @notice Hook that is called before any transfer of tokens (including minting and burning).
     * @dev Enforces OpenZeppelin v5 Pausable check + Bidirectional KYC whitelist + Frozen checks.
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Pausable) {
        // Enforce pause state via ERC20Pausable
        super._update(from, to, value);

        // 1. Check Sender compliance (skip on minting where from == address(0))
        if (from != address(0)) {
            if (!_kycApproved[from]) {
                revert SenderNotKYCApproved(from);
            }
            if (_frozen[from]) {
                revert AccountFrozen(from);
            }
        }

        // 2. Check Recipient compliance (skip on burning where to == address(0))
        if (to != address(0)) {
            if (!_kycApproved[to]) {
                revert RecipientNotKYCApproved(to);
            }
            if (_frozen[to]) {
                revert AccountFrozen(to);
            }
        }
    }
}
