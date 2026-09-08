const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("AutoStack", function () {
  let autostack, owner, alice, bob, keeper;
  const ONE = ethers.parseEther("1");
  const HOUR = 3600;
  const DAY = 86400;

  beforeEach(async () => {
    [owner, alice, bob, keeper] = await ethers.getSigners();
    const F = await ethers.getContractFactory("AutoStack");
    autostack = await F.deploy();
    await autostack.waitForDeployment();
  });

  it("deposit adds idle balance", async () => {
    await autostack.connect(alice).deposit({ value: ONE });
    expect(await autostack.getIdleBalance(alice.address)).to.equal(ONE);
  });

  it("createPlan validates inputs", async () => {
    await expect(autostack.connect(alice).createPlan(0, DAY, 10)).to.be.revertedWith("zero amount");
    await expect(autostack.connect(alice).createPlan(ONE, 60, 10)).to.be.revertedWith("cycle too short");
    await expect(autostack.connect(alice).createPlan(ONE, DAY, 0)).to.be.revertedWith("bad cycles");
    await expect(autostack.connect(alice).createPlan(ONE, DAY, 1001)).to.be.revertedWith("bad cycles");
    await autostack.connect(alice).createPlan(ONE, DAY, 5);
    expect(await autostack.planCount()).to.equal(1n);
  });

  it("execute respects cycle timing", async () => {
    await autostack.connect(alice).deposit({ value: ethers.parseEther("10") });
    await autostack.connect(alice).createPlan(ONE, DAY, 3);
    await expect(autostack.connect(keeper).execute(0)).to.be.revertedWith("cycle not due");
    await time.increase(DAY + 1);
    await autostack.connect(keeper).execute(0);
    const plan = await autostack.getPlan(0);
    expect(plan.cyclesExecuted).to.equal(1);
  });

  it("execute requires sufficient idle balance", async () => {
    await autostack.connect(alice).deposit({ value: ethers.parseEther("0.5") });
    await autostack.connect(alice).createPlan(ONE, DAY, 3);
    await time.increase(DAY + 1);
    await expect(autostack.connect(keeper).execute(0)).to.be.revertedWith("owner idle insufficient");
  });

  it("cycles complete -> status Completed", async () => {
    await autostack.connect(alice).deposit({ value: ethers.parseEther("10") });
    await autostack.connect(alice).createPlan(ONE, HOUR, 2);
    await time.increase(HOUR + 1);
    await autostack.connect(keeper).execute(0);
    await time.increase(HOUR + 1);
    await autostack.connect(keeper).execute(0);
    const plan = await autostack.getPlan(0);
    expect(plan.status).to.equal(2); // Completed
    await time.increase(HOUR + 1);
    await expect(autostack.connect(keeper).execute(0)).to.be.revertedWith("plan not active");
  });

  it("only owner can pause/resume/cancel plan", async () => {
    await autostack.connect(alice).createPlan(ONE, DAY, 3);
    await expect(autostack.connect(bob).pausePlan(0)).to.be.revertedWith("not owner");
    await autostack.connect(alice).pausePlan(0);
    expect((await autostack.getPlan(0)).status).to.equal(1);
    await expect(autostack.connect(bob).resumePlan(0)).to.be.revertedWith("not owner");
    await autostack.connect(alice).resumePlan(0);
    expect((await autostack.getPlan(0)).status).to.equal(0);
    await expect(autostack.connect(bob).cancelPlan(0)).to.be.revertedWith("not owner");
    await autostack.connect(alice).cancelPlan(0);
    expect((await autostack.getPlan(0)).status).to.equal(3);
  });

  it("paused plan cannot execute", async () => {
    await autostack.connect(alice).deposit({ value: ethers.parseEther("10") });
    await autostack.connect(alice).createPlan(ONE, DAY, 3);
    await autostack.connect(alice).pausePlan(0);
    await time.increase(DAY + 1);
    await expect(autostack.connect(keeper).execute(0)).to.be.revertedWith("plan not active");
  });

  it("caller reward paid to msg.sender", async () => {
    await autostack.connect(alice).deposit({ value: ethers.parseEther("10") });
    await autostack.connect(alice).createPlan(ONE, DAY, 3);
    await time.increase(DAY + 1);
    const before = await ethers.provider.getBalance(keeper.address);
    const tx = await autostack.connect(keeper).execute(0);
    const rc = await tx.wait();
    const gas = rc.gasUsed * rc.gasPrice;
    const after = await ethers.provider.getBalance(keeper.address);
    // reward = 25 bps of 1 ETH = 0.0025 ETH
    const expectedReward = ONE * 25n / 10000n;
    expect(after - before + gas).to.equal(expectedReward);
  });

  it("withdraw idle and stacked correctly", async () => {
    await autostack.connect(alice).deposit({ value: ethers.parseEther("5") });
    await autostack.connect(alice).createPlan(ONE, DAY, 1);
    await time.increase(DAY + 1);
    await autostack.connect(keeper).execute(0);
    // idle = 5 - 1 = 4, stacked = 1 - 0.005 fee = 0.995
    expect(await autostack.getIdleBalance(alice.address)).to.equal(ethers.parseEther("4"));
    const stacked = await autostack.getStackedBalance(alice.address);
    expect(stacked).to.equal(ethers.parseEther("0.995"));
    await autostack.connect(alice).withdrawIdle(ethers.parseEther("2"));
    expect(await autostack.getIdleBalance(alice.address)).to.equal(ethers.parseEther("2"));
    await autostack.connect(alice).withdrawStacked(stacked);
    expect(await autostack.getStackedBalance(alice.address)).to.equal(0n);
  });

  it("canExecute and nextExecutionTime views", async () => {
    await autostack.connect(alice).deposit({ value: ethers.parseEther("10") });
    await autostack.connect(alice).createPlan(ONE, DAY, 3);
    expect(await autostack.canExecute(0)).to.equal(false);
    await time.increase(DAY + 1);
    expect(await autostack.canExecute(0)).to.equal(true);
    const next = await autostack.nextExecutionTime(0);
    expect(next).to.be.gt(0n);
  });

  it("getPlansByOwner and getPurchases populate", async () => {
    await autostack.connect(alice).deposit({ value: ethers.parseEther("5") });
    await autostack.connect(alice).createPlan(ONE, HOUR, 2);
    await autostack.connect(alice).createPlan(ONE, HOUR, 2);
    const ids = await autostack.getPlansByOwner(alice.address);
    expect(ids.length).to.equal(2);
    await time.increase(HOUR + 1);
    await autostack.connect(keeper).execute(0);
    const [blocks, amounts, ts] = await autostack.getPurchases(0);
    expect(blocks.length).to.equal(1);
    expect(amounts[0]).to.equal(ethers.parseEther("0.995"));
    expect(ts[0]).to.be.gt(0n);
  });

  it("admin fees and pause", async () => {
    await autostack.connect(alice).deposit({ value: ethers.parseEther("10") });
    await autostack.connect(alice).createPlan(ONE, DAY, 1);
    await time.increase(DAY + 1);
    await autostack.connect(keeper).execute(0);
    // fee = 50 bps of 1 = 0.005; caller reward = 0.0025; kept = 0.0025
    const fees = await autostack.accumulatedFees();
    expect(fees).to.equal(ethers.parseEther("0.0025"));
    await autostack.connect(owner).withdrawFees(owner.address, fees);
    expect(await autostack.accumulatedFees()).to.equal(0n);

    await autostack.connect(owner).pause();
    await expect(autostack.connect(alice).deposit({ value: ONE })).to.be.reverted;
    await autostack.connect(owner).unpause();
  });

  it("accounting invariant: contract balance == idle + stacked + fees", async () => {
    await autostack.connect(alice).deposit({ value: ethers.parseEther("5") });
    await autostack.connect(bob).deposit({ value: ethers.parseEther("3") });
    await autostack.connect(alice).createPlan(ONE, HOUR, 2);
    await time.increase(HOUR + 1);
    await autostack.connect(keeper).execute(0);
    await time.increase(HOUR + 1);
    await autostack.connect(keeper).execute(0);

    const addr = await autostack.getAddress();
    const bal = await ethers.provider.getBalance(addr);
    const aIdle = await autostack.getIdleBalance(alice.address);
    const bIdle = await autostack.getIdleBalance(bob.address);
    const aStacked = await autostack.getStackedBalance(alice.address);
    const bStacked = await autostack.getStackedBalance(bob.address);
    const fees = await autostack.accumulatedFees();
    expect(bal).to.equal(aIdle + bIdle + aStacked + bStacked + fees);
  });
});
