import { expect } from "chai";
import { network } from "hardhat";

describe("APXGold (Compliance & Vault-Backed Metal Token)", function () {

    async function deployAPXGoldFixture() {
        const { ethers } = await network.connect();

        const [
            admin,
            minter,
            kycManager,
            burner,
            investorAlice,
            investorBob,
            unverifiedCharlie,
            attacker
        ] = await ethers.getSigners();

        const vaultLocation = "Zurich, Switzerland - Vault Facility #4";
        const APXGoldFactory = await ethers.getContractFactory("APXGold");
        const apxGold = await APXGoldFactory.deploy(admin.address, vaultLocation);
        await apxGold.waitForDeployment();

        // Grant specific roles to designated accounts
        const MINTER_ROLE = await apxGold.MINTER_ROLE();
        const BURNER_ROLE = await apxGold.BURNER_ROLE();
        const KYC_MANAGER_ROLE = await apxGold.KYC_MANAGER_ROLE();
        const PAUSER_ROLE = await apxGold.PAUSER_ROLE();

        await apxGold.connect(admin).grantRole(MINTER_ROLE, minter.address);
        await apxGold.connect(admin).grantRole(BURNER_ROLE, burner.address);
        await apxGold.connect(admin).grantRole(KYC_MANAGER_ROLE, kycManager.address);

        // Pre-approve Alice and Bob for KYC compliance tests
        await apxGold.connect(kycManager).setKYCStatus(investorAlice.address, true);
        await apxGold.connect(kycManager).setKYCStatus(investorBob.address, true);

        return {
            apxGold,
            admin,
            minter,
            kycManager,
            burner,
            investorAlice,
            investorBob,
            unverifiedCharlie,
            attacker,
            MINTER_ROLE,
            BURNER_ROLE,
            KYC_MANAGER_ROLE,
            PAUSER_ROLE,
            ethers
        };
    }

    // =========================================================================
    // 1. DEPLOYMENT & INITIAL ROLE CONFIGURATION
    // =========================================================================
    describe("1. Deployment & Roles", function () {
        it("Should set the correct token name, symbol, and vault metadata", async function () {
            const { apxGold } = await deployAPXGoldFixture();
            expect(await apxGold.name()).to.equal("APAX Gold Token");
            expect(await apxGold.symbol()).to.equal("APX-GOLD");
            expect(await apxGold.vaultLocation()).to.equal("Zurich, Switzerland - Vault Facility #4");
            expect(await apxGold.decimals()).to.equal(18);
        });

        it("Should assign DEFAULT_ADMIN_ROLE and operational roles to admin", async function () {
            const { apxGold, admin } = await deployAPXGoldFixture();
            const DEFAULT_ADMIN = await apxGold.DEFAULT_ADMIN_ROLE();
            expect(await apxGold.hasRole(DEFAULT_ADMIN, admin.address)).to.be.true;
        });

        it("Should automatically pre-approve admin for KYC transfers", async function () {
            const { apxGold, admin } = await deployAPXGoldFixture();
            expect(await apxGold.isKYCApproved(admin.address)).to.be.true;
        });
    });

    // =========================================================================
    // 2. KYC & COMPLIANCE REGISTRY
    // =========================================================================
    describe("2. KYC & Compliance Gates", function () {
        it("Should allow KYC Manager to approve and revoke investor status", async function () {
            const { apxGold, kycManager, unverifiedCharlie } = await deployAPXGoldFixture();

            expect(await apxGold.isKYCApproved(unverifiedCharlie.address)).to.be.false;

            // Approve Charlie
            await expect(apxGold.connect(kycManager).setKYCStatus(unverifiedCharlie.address, true))
                .to.emit(apxGold, "KYCStatusUpdated")
                .withArgs(unverifiedCharlie.address, true, kycManager.address);
            expect(await apxGold.isKYCApproved(unverifiedCharlie.address)).to.be.true;

            // Revoke Charlie
            await apxGold.connect(kycManager).setKYCStatus(unverifiedCharlie.address, false);
            expect(await apxGold.isKYCApproved(unverifiedCharlie.address)).to.be.false;
        });

        it("Should revert if an unauthorized account attempts to update KYC", async function () {
            const { apxGold, attacker, unverifiedCharlie } = await deployAPXGoldFixture();
            await expect(
                apxGold.connect(attacker).setKYCStatus(unverifiedCharlie.address, true)
            ).to.be.reverted;
        });

        it("Should support batch KYC updates for gas efficiency", async function () {
            const { apxGold, kycManager, ethers } = await deployAPXGoldFixture();
            const wallet1 = ethers.Wallet.createRandom().address;
            const wallet2 = ethers.Wallet.createRandom().address;

            await apxGold.connect(kycManager).batchSetKYCStatus([wallet1, wallet2], true);
            expect(await apxGold.isKYCApproved(wallet1)).to.be.true;
            expect(await apxGold.isKYCApproved(wallet2)).to.be.true;
        });

        it("Should allow freezing and unfreezing an account", async function () {
            const { apxGold, kycManager, investorAlice } = await deployAPXGoldFixture();

            await expect(apxGold.connect(kycManager).setAccountFreeze(investorAlice.address, true))
                .to.emit(apxGold, "AccountFreezeUpdated")
                .withArgs(investorAlice.address, true, kycManager.address);

            expect(await apxGold.isFrozen(investorAlice.address)).to.be.true;
        });
    });

    // =========================================================================
    // 3. VAULT-BACKED MINTING
    // =========================================================================
    describe("3. Vault-Backed Minting", function () {
        const goldGrams = 100n * 10n ** 18n; // 100 grams
        const serialNo = "AU-BAR-2026-99482";
        const auditHash = "ipfs://QmZ8F91A...auditReport.pdf";

        it("Should allow MINTER_ROLE to mint to a KYC-approved recipient with audit proof", async function () {
            const { apxGold, minter, investorAlice } = await deployAPXGoldFixture();

            await expect(
                apxGold.connect(minter).mintWithVaultProof(
                    investorAlice.address,
                    goldGrams,
                    serialNo,
                    auditHash
                )
            ).to.emit(apxGold, "VaultDepositMinted")
             .withArgs(investorAlice.address, goldGrams, serialNo, auditHash);

            expect(await apxGold.balanceOf(investorAlice.address)).to.equal(goldGrams);
            expect(await apxGold.totalSupply()).to.equal(goldGrams);
        });

        it("Should REVERT minting if the recipient is NOT KYC-approved", async function () {
            const { apxGold, minter, unverifiedCharlie } = await deployAPXGoldFixture();

            await expect(
                apxGold.connect(minter).mintWithVaultProof(
                    unverifiedCharlie.address,
                    goldGrams,
                    serialNo,
                    auditHash
                )
            ).to.be.revertedWithCustomError(apxGold, "RecipientNotKYCApproved")
             .withArgs(unverifiedCharlie.address);
        });

        it("Should REVERT minting if called by non-minter", async function () {
            const { apxGold, attacker, investorAlice } = await deployAPXGoldFixture();

            await expect(
                apxGold.connect(attacker).mintWithVaultProof(
                    investorAlice.address,
                    goldGrams,
                    serialNo,
                    auditHash
                )
            ).to.be.reverted;
        });
    });

    // =========================================================================
    // 4. TRANSFER RESTRICTIONS & GOVERNED TRANSFERS
    // =========================================================================
    describe("4. Transfer Restrictions (Governed Transfers)", function () {
        const transferAmount = 25n * 10n ** 18n;

        beforeEach(async function () {
            // Mint 100 grams to Alice first
        });

        it("Should allow transfer between two KYC-approved accounts", async function () {
            const { apxGold, minter, investorAlice, investorBob } = await deployAPXGoldFixture();
            const initialGrams = 100n * 10n ** 18n;

            await apxGold.connect(minter).mintWithVaultProof(
                investorAlice.address,
                initialGrams,
                "BAR-01",
                "DOC-01"
            );

            await apxGold.connect(investorAlice).transfer(investorBob.address, transferAmount);

            expect(await apxGold.balanceOf(investorAlice.address)).to.equal(initialGrams - transferAmount);
            expect(await apxGold.balanceOf(investorBob.address)).to.equal(transferAmount);
        });

        it("Should REVERT transfer if recipient is NOT KYC-approved", async function () {
            const { apxGold, minter, investorAlice, unverifiedCharlie } = await deployAPXGoldFixture();

            await apxGold.connect(minter).mintWithVaultProof(
                investorAlice.address,
                50n * 10n ** 18n,
                "BAR-02",
                "DOC-02"
            );

            await expect(
                apxGold.connect(investorAlice).transfer(unverifiedCharlie.address, 10n * 10n ** 18n)
            ).to.be.revertedWithCustomError(apxGold, "RecipientNotKYCApproved")
             .withArgs(unverifiedCharlie.address);
        });

        it("Should REVERT transfer if sender KYC has been revoked", async function () {
            const { apxGold, minter, kycManager, investorAlice, investorBob } = await deployAPXGoldFixture();

            await apxGold.connect(minter).mintWithVaultProof(
                investorAlice.address,
                50n * 10n ** 18n,
                "BAR-03",
                "DOC-03"
            );

            // Revoke Alice's KYC
            await apxGold.connect(kycManager).setKYCStatus(investorAlice.address, false);

            await expect(
                apxGold.connect(investorAlice).transfer(investorBob.address, 10n * 10n ** 18n)
            ).to.be.revertedWithCustomError(apxGold, "SenderNotKYCApproved")
             .withArgs(investorAlice.address);
        });

        it("Should REVERT transfer if sender or recipient is FROZEN", async function () {
            const { apxGold, minter, kycManager, investorAlice, investorBob } = await deployAPXGoldFixture();

            await apxGold.connect(minter).mintWithVaultProof(
                investorAlice.address,
                50n * 10n ** 18n,
                "BAR-04",
                "DOC-04"
            );

            // Freeze Alice
            await apxGold.connect(kycManager).setAccountFreeze(investorAlice.address, true);

            await expect(
                apxGold.connect(investorAlice).transfer(investorBob.address, 10n * 10n ** 18n)
            ).to.be.revertedWithCustomError(apxGold, "AccountFrozen")
             .withArgs(investorAlice.address);
        });
    });

    // =========================================================================
    // 5. PHYSICAL REDEMPTION & BURNING
    // =========================================================================
    describe("5. Physical Redemption & Burning", function () {
        const initialGold = 50n * 10n ** 18n;
        const redeemGrams = 20n * 10n ** 18n;
        const manifestRef = "DHL-EXPRESS-INSURED-MANIFEST-#99281";

        it("Should allow BURNER_ROLE to burn tokens upon verified physical delivery", async function () {
            const { apxGold, minter, burner, investorAlice } = await deployAPXGoldFixture();

            await apxGold.connect(minter).mintWithVaultProof(
                investorAlice.address,
                initialGold,
                "BAR-05",
                "DOC-05"
            );

            await expect(
                apxGold.connect(burner).burnForRedemption(
                    investorAlice.address,
                    redeemGrams,
                    manifestRef
                )
            ).to.emit(apxGold, "PhysicalRedemptionBurnt")
             .withArgs(investorAlice.address, redeemGrams, manifestRef);

            expect(await apxGold.balanceOf(investorAlice.address)).to.equal(initialGold - redeemGrams);
            expect(await apxGold.totalSupply()).to.equal(initialGold - redeemGrams);
        });

        it("Should REVERT burn if called by unauthorized account", async function () {
            const { apxGold, attacker, investorAlice } = await deployAPXGoldFixture();

            await expect(
                apxGold.connect(attacker).burnForRedemption(
                    investorAlice.address,
                    10n * 10n ** 18n,
                    manifestRef
                )
            ).to.be.reverted;
        });
    });

    // =========================================================================
    // 6. EMERGENCY PAUSE (CIRCUIT BREAKER)
    // =========================================================================
    describe("6. Emergency Pause", function () {
        it("Should halt all transfers when contract is paused and resume upon unpause", async function () {
            const { apxGold, admin, minter, investorAlice, investorBob } = await deployAPXGoldFixture();

            await apxGold.connect(minter).mintWithVaultProof(
                investorAlice.address,
                30n * 10n ** 18n,
                "BAR-06",
                "DOC-06"
            );

            // Trigger emergency pause
            await apxGold.connect(admin).pause();

            // Transfers must revert
            await expect(
                apxGold.connect(investorAlice).transfer(investorBob.address, 10n * 10n ** 18n)
            ).to.be.revertedWithCustomError(apxGold, "EnforcedPause");

            // Unpause and verify transfers resume
            await apxGold.connect(admin).unpause();
            await expect(
                apxGold.connect(investorAlice).transfer(investorBob.address, 10n * 10n ** 18n)
            ).to.not.be.reverted;
        });
    });
});
