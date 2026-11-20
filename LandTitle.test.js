const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Land title system", () => {
  let admin, governor, registrar, treasury, owner, buyer, randomUser;
  let nft, registry, token, tokenId;

  const REG_FEE = 500000n;   // N5,000.00 (2 decimals)
  const XFER_FEE = 250000n;  // N2,500.00

  const parcelId = ethers.keccak256(ethers.toUtf8Bytes("parcel-001"));
  const spatialHash = ethers.keccak256(ethers.toUtf8Bytes("polygon-001"));
  const app = (s) => ethers.keccak256(ethers.toUtf8Bytes(s));

  // Backend flow: naira payment confirmed -> mint credit -> user approves registry
  async function fund(user, amount) {
    await token.connect(admin).mint(user.address, amount); // admin holds MINTER_ROLE
    await token.connect(user).approve(await registry.getAddress(), amount);
  }

  beforeEach(async () => {
    [admin, governor, registrar, treasury, owner, buyer, randomUser] = await ethers.getSigners();

    token = await (await ethers.getContractFactory("LandFeeToken")).deploy(
      admin.address, admin.address, treasury.address
    );
    nft = await (await ethers.getContractFactory("LandTitleNFT")).deploy(admin.address, governor.address);
    registry = await (await ethers.getContractFactory("LandRegistry")).deploy(
      admin.address, await nft.getAddress(), await token.getAddress(), REG_FEE, XFER_FEE
    );

    await nft.connect(admin).grantRole(await nft.REGISTRY_ROLE(), await registry.getAddress());
    await registry.connect(admin).grantRole(await registry.REGISTRAR_ROLE(), registrar.address);

    await fund(owner, REG_FEE * 3n);
    await registry.connect(registrar).registerTitle(app("app-1"), owner.address, parcelId, spatialHash, "ipfs://title-1");
    tokenId = 1n;
  });

  describe("Fee token", () => {
    it("charges the registration fee to the treasury on issuance", async () => {
      expect(await token.balanceOf(treasury.address)).to.equal(REG_FEE);
      expect(await token.balanceOf(owner.address)).to.equal(REG_FEE * 2n);
      expect(await registry.totalFeesCollected()).to.equal(REG_FEE);
    });

    it("reverts registration when the payer has no approved credit", async () => {
      await expect(
        registry.connect(registrar).registerTitle(
          app("app-x"), randomUser.address,
          ethers.keccak256(ethers.toUtf8Bytes("parcel-x")), spatialHash, "x"
        )
      ).to.be.reverted;
    });

    it("blocks user-to-user token transfers (closed loop)", async () => {
      await expect(token.connect(owner).transfer(buyer.address, 100n))
        .to.be.revertedWith("LandFeeToken: closed-loop transfers only");
    });

    it("only the minter can mint or burn", async () => {
      await expect(token.connect(randomUser).mint(randomUser.address, 1n)).to.be.reverted;
      await expect(token.connect(randomUser).burn(owner.address, 1n)).to.be.reverted;
    });

    it("lets the admin update the fee schedule", async () => {
      await registry.connect(admin).setFee(0, 100n);
      expect(await registry.fees(0)).to.equal(100n);
      await expect(registry.connect(randomUser).setFee(0, 1n)).to.be.reverted;
    });
  });

  describe("Issuance and transfers", () => {
    it("issues an NFT title to the verified owner", async () => {
      expect(await nft.ownerOf(tokenId)).to.equal(owner.address);
      expect(await registry.titlesIssued()).to.equal(1n);
    });

    it("rejects duplicate application replay", async () => {
      await expect(
        registry.connect(registrar).registerTitle(app("app-1"), owner.address, parcelId, spatialHash, "x")
      ).to.be.revertedWith("LandRegistry: application already processed");
    });

    it("rejects a second title on the same parcel", async () => {
      await fund(buyer, REG_FEE);
      await expect(
        registry.connect(registrar).registerTitle(app("app-2"), buyer.address, parcelId, spatialHash, "x")
      ).to.be.revertedWith("LandTitleNFT: parcel already titled");
    });

    it("completes a registry-controlled transfer and charges the buyer", async () => {
      await fund(buyer, XFER_FEE);
      await registry.connect(registrar).transferTitle(app("app-3"), tokenId, buyer.address);
      expect(await nft.ownerOf(tokenId)).to.equal(buyer.address);
      expect(await token.balanceOf(buyer.address)).to.equal(0n);
      expect(await registry.transfersCompleted()).to.equal(1n);
    });

    it("rejects owner-initiated transfers and approvals", async () => {
      await expect(
        nft.connect(owner).transferFrom(owner.address, buyer.address, tokenId)
      ).to.be.revertedWith("LandTitleNFT: owner-initiated transfers disabled");
      await expect(nft.connect(owner).approve(buyer.address, tokenId)).to.be.reverted;
    });

    it("rejects non-registrar registration", async () => {
      await expect(
        registry.connect(randomUser).registerTitle(app("app-9"), buyer.address, parcelId, spatialHash, "x")
      ).to.be.reverted;
    });
  });

  describe("Statutory revocation", () => {
    it("allows the Governor-role address to revoke a title", async () => {
      await expect(nft.connect(governor).revoke(tokenId, 0)).to.emit(nft, "TitleRevoked");
      expect(await nft.isRevoked(tokenId)).to.equal(true);
    });

    it("reverts when a non-Governor address attempts to revoke", async () => {
      await expect(nft.connect(randomUser).revoke(tokenId, 0)).to.be.reverted;
    });

    it("reverts any transfer attempt on a revoked token", async () => {
      await nft.connect(governor).revoke(tokenId, 1);
      await expect(
        nft.connect(owner).transferFrom(owner.address, buyer.address, tokenId)
      ).to.be.reverted;
      await expect(
        registry.connect(registrar).transferTitle(app("app-4"), tokenId, buyer.address)
      ).to.be.revertedWith("LandRegistry: title revoked");
    });

    it("cannot revoke twice, or a non-existent token", async () => {
      await nft.connect(governor).revoke(tokenId, 0);
      await expect(nft.connect(governor).revoke(tokenId, 0)).to.be.revertedWith("LandTitleNFT: already revoked");
      await expect(nft.connect(governor).revoke(99, 0)).to.be.reverted;
    });

    it("lets the registry re-issue a parcel after revocation", async () => {
      await nft.connect(governor).revoke(tokenId, 0);
      await fund(buyer, REG_FEE);
      await registry.connect(registrar).registerTitle(app("app-5"), buyer.address, parcelId, spatialHash, "ipfs://title-2");
      expect(await nft.ownerOf(2n)).to.equal(buyer.address);
    });

    it("measures gas for revoke() (feeds Table B)", async () => {
      const tx = await nft.connect(governor).revoke(tokenId, 0);
      const receipt = await tx.wait();
      console.log("revoke() gas used:", receipt.gasUsed.toString());
    });
  });
});
