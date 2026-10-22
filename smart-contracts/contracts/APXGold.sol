// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';

/**
 * @title APXGold
 * @notice ERC-20 token with KYC checks, account freezing, and pause controls.
 * @dev Custody and redemption verification take place off-chain.
 */
contract APXGold is ERC20, ERC20Pausable, AccessControl {
  // Roles
  bytes32 public constant MINTER_ROLE = keccak256('MINTER_ROLE');
  bytes32 public constant BURNER_ROLE = keccak256('BURNER_ROLE');
  bytes32 public constant KYC_MANAGER_ROLE = keccak256('KYC_MANAGER_ROLE');
  bytes32 public constant PAUSER_ROLE = keccak256('PAUSER_ROLE');

  // Compliance status
  mapping(address => bool) private _kycApproved;
  mapping(address => bool) private _frozen;

  // Vault information
  string public vaultLocation;
  string public constant METAL_TYPE = 'Gold (Au) 99.99% Purity';

  // Custom errors
  error SenderNotKYCApproved(address sender);
  error RecipientNotKYCApproved(address recipient);
  error AccountFrozen(address account);
  error ZeroAddressNotAllowed();
  error ZeroAmountNotAllowed();
  error EmptyReceiptIdentifier();

  // Events
  event KYCStatusUpdated(address indexed account, bool indexed status, address indexed operator);
  event AccountFreezeUpdated(
    address indexed account,
    bool indexed isFrozen,
    address indexed operator
  );
  event VaultDepositMinted(
    address indexed recipient,
    uint256 amount,
    string vaultBarSerialNumber,
    string auditProofRef
  );
  event PhysicalRedemptionBurnt(address indexed holder, uint256 amount, string deliveryOrderRef);
  event VaultLocationUpdated(string newLocation, address indexed operator);

  /**
   * @param admin Address that receives the initial roles.
   * @param initialVaultLocation Initial vault location description.
   */
  constructor(
    address admin,
    string memory initialVaultLocation
  ) ERC20('APAX Gold Token', 'APX-GOLD') {
    if (admin == address(0)) revert ZeroAddressNotAllowed();

    vaultLocation = initialVaultLocation;

    // Assign the initial roles.
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(MINTER_ROLE, admin);
    _grantRole(BURNER_ROLE, admin);
    _grantRole(KYC_MANAGER_ROLE, admin);
    _grantRole(PAUSER_ROLE, admin);

    // Allow the admin account to use the token during setup.
    _kycApproved[admin] = true;
    emit KYCStatusUpdated(admin, true, msg.sender);
  }

  // KYC and account status
  /** @notice Sets or removes KYC approval for an address. */
  function setKYCStatus(address account, bool status) external onlyRole(KYC_MANAGER_ROLE) {
    if (account == address(0)) revert ZeroAddressNotAllowed();
    _kycApproved[account] = status;
    emit KYCStatusUpdated(account, status, msg.sender);
  }

  /** @notice Sets KYC approval for multiple addresses. */
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

  /** @notice Freezes or unfreezes an address. */
  function setAccountFreeze(
    address account,
    bool frozenStatus
  ) external onlyRole(KYC_MANAGER_ROLE) {
    if (account == address(0)) revert ZeroAddressNotAllowed();
    _frozen[account] = frozenStatus;
    emit AccountFreezeUpdated(account, frozenStatus, msg.sender);
  }

  /** @notice Returns whether an address is KYC approved. */
  function isKYCApproved(address account) external view returns (bool) {
    return _kycApproved[account];
  }

  /** @notice Returns whether an address is frozen. */
  function isFrozen(address account) external view returns (bool) {
    return _frozen[account];
  }

  // Minting and redemption
  /**
   * @notice Mints tokens to an approved address.
   * @dev Custody deposit verification is handled outside the contract.
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
   * @notice Burns tokens as part of a redemption.
   * @dev The caller is responsible for confirming the off-chain delivery process.
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

  // Emergency pause
  /** @notice Pauses token transfers. */
  function pause() external onlyRole(PAUSER_ROLE) {
    _pause();
  }

  /** @notice Resumes token transfers. */
  function unpause() external onlyRole(PAUSER_ROLE) {
    _unpause();
  }

  /** @notice Updates the vault location description. */
  function updateVaultLocation(string calldata newLocation) external onlyRole(DEFAULT_ADMIN_ROLE) {
    vaultLocation = newLocation;
    emit VaultLocationUpdated(newLocation, msg.sender);
  }

  // Transfer checks
  /**
   * @dev Applies pause and compliance checks to transfers, minting, and burning.
   */
  function _update(
    address from,
    address to,
    uint256 value
  ) internal override(ERC20, ERC20Pausable) {
    super._update(from, to, value);

    if (from != address(0)) {
      if (!_kycApproved[from]) {
        revert SenderNotKYCApproved(from);
      }
      if (_frozen[from]) {
        revert AccountFrozen(from);
      }
    }

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
