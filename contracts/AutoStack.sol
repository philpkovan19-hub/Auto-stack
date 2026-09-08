// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title AutoStack
 * @notice Recurring DCA vault for native BOT. Users deposit idle balance and
 *         create plans that move `amountPerCycle` from idle -> stacked on a
 *         fixed cadence. Anyone may call `execute` for a due plan and earn a
 *         caller reward, funded from the platform fee. Because there is no
 *         swap partner, stacked balance is denominated in BOT 1:1 with idle
 *         (a demo/simulation). The purchase price recorded is the block number
 *         at execution time.
 */
contract AutoStack is Ownable, ReentrancyGuard, Pausable {
    enum PlanStatus { Active, Paused, Completed, Cancelled }

    struct Purchase {
        uint256 blockNumber;
        uint256 amount;
        uint256 timestamp;
    }

    struct Plan {
        address owner;
        uint256 amountPerCycle;
        uint256 cycleSecs;
        uint16 totalCycles;
        uint16 cyclesExecuted;
        uint256 startTime;
        uint256 lastExecutedAt;
        PlanStatus status;
    }

    uint256 public constant MIN_CYCLE_SECS = 1 hours;
    uint16 public constant MAX_TOTAL_CYCLES = 1000;
    uint16 public constant BPS_DENOM = 10_000;

    uint16 public platformFeeBps = 50; // 0.5%
    uint16 public callerRewardBps = 25; // 0.25% (paid from platform fee share)

    uint256 public planCount;
    uint256 public accumulatedFees;

    mapping(uint256 => Plan) private _plans;
    mapping(uint256 => Purchase[]) private _purchases;
    mapping(address => uint256[]) private _plansByOwner;
    mapping(address => uint256) private _idleBalance;
    mapping(address => uint256) private _stackedBalance;

    event Deposited(address indexed user, uint256 amount);
    event PlanCreated(uint256 indexed planId, address indexed owner, uint256 amountPerCycle, uint256 cycleSecs, uint16 totalCycles);
    event PlanExecuted(uint256 indexed planId, uint16 cycleNumber, uint256 amount, address indexed caller, uint256 callerReward);
    event PlanPaused(uint256 indexed planId);
    event PlanResumed(uint256 indexed planId);
    event PlanCancelled(uint256 indexed planId);
    event Withdrawn(address indexed user, uint256 amount, bool fromStacked);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event PlatformFeeUpdated(uint16 bps);
    event CallerRewardUpdated(uint16 bps);

    constructor() Ownable(msg.sender) {}

    // ------------------------------------------------------------------
    // Deposits / withdrawals
    // ------------------------------------------------------------------

    function deposit() external payable whenNotPaused {
        require(msg.value > 0, "zero deposit");
        _idleBalance[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    receive() external payable {
        require(msg.value > 0, "zero deposit");
        _idleBalance[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    function withdrawIdle(uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");
        require(_idleBalance[msg.sender] >= amount, "insufficient idle");
        _idleBalance[msg.sender] -= amount;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "transfer failed");
        emit Withdrawn(msg.sender, amount, false);
    }

    function withdrawStacked(uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");
        require(_stackedBalance[msg.sender] >= amount, "insufficient stacked");
        _stackedBalance[msg.sender] -= amount;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "transfer failed");
        emit Withdrawn(msg.sender, amount, true);
    }

    // ------------------------------------------------------------------
    // Plan lifecycle
    // ------------------------------------------------------------------

    function createPlan(
        uint256 amountPerCycle,
        uint256 cycleSecs,
        uint16 totalCycles
    ) external whenNotPaused returns (uint256 planId) {
        require(amountPerCycle > 0, "zero amount");
        require(cycleSecs >= MIN_CYCLE_SECS, "cycle too short");
        require(totalCycles > 0 && totalCycles <= MAX_TOTAL_CYCLES, "bad cycles");

        planId = planCount++;
        _plans[planId] = Plan({
            owner: msg.sender,
            amountPerCycle: amountPerCycle,
            cycleSecs: cycleSecs,
            totalCycles: totalCycles,
            cyclesExecuted: 0,
            startTime: block.timestamp,
            lastExecutedAt: 0,
            status: PlanStatus.Active
        });
        _plansByOwner[msg.sender].push(planId);
        emit PlanCreated(planId, msg.sender, amountPerCycle, cycleSecs, totalCycles);
    }

    function pausePlan(uint256 planId) external {
        Plan storage p = _plans[planId];
        require(p.owner == msg.sender, "not owner");
        require(p.status == PlanStatus.Active, "not active");
        p.status = PlanStatus.Paused;
        emit PlanPaused(planId);
    }

    function resumePlan(uint256 planId) external {
        Plan storage p = _plans[planId];
        require(p.owner == msg.sender, "not owner");
        require(p.status == PlanStatus.Paused, "not paused");
        p.status = PlanStatus.Active;
        emit PlanResumed(planId);
    }

    function cancelPlan(uint256 planId) external {
        Plan storage p = _plans[planId];
        require(p.owner == msg.sender, "not owner");
        require(p.status == PlanStatus.Active || p.status == PlanStatus.Paused, "already ended");
        p.status = PlanStatus.Cancelled;
        emit PlanCancelled(planId);
    }

    function execute(uint256 planId) external nonReentrant whenNotPaused {
        Plan storage p = _plans[planId];
        require(p.owner != address(0), "no plan");
        require(p.status == PlanStatus.Active, "plan not active");
        require(p.cyclesExecuted < p.totalCycles, "plan finished");

        uint256 dueAt = p.lastExecutedAt == 0
            ? p.startTime + p.cycleSecs
            : p.lastExecutedAt + p.cycleSecs;
        require(block.timestamp >= dueAt, "cycle not due");

        uint256 amount = p.amountPerCycle;
        require(_idleBalance[p.owner] >= amount, "owner idle insufficient");

        // Split fee and caller reward. Caller reward is taken from the
        // platform fee slice (capped so we can't over-pay callers).
        uint256 feeTotal = (amount * platformFeeBps) / BPS_DENOM;
        uint256 rewardCap = (amount * callerRewardBps) / BPS_DENOM;
        uint256 callerReward = rewardCap > feeTotal ? feeTotal : rewardCap;
        uint256 keptFee = feeTotal - callerReward;

        uint256 stackedAmount = amount - feeTotal;

        _idleBalance[p.owner] -= amount;
        _stackedBalance[p.owner] += stackedAmount;
        accumulatedFees += keptFee;

        p.cyclesExecuted += 1;
        p.lastExecutedAt = block.timestamp;
        if (p.cyclesExecuted == p.totalCycles) {
            p.status = PlanStatus.Completed;
        }

        _purchases[planId].push(Purchase({
            blockNumber: block.number,
            amount: stackedAmount,
            timestamp: block.timestamp
        }));

        if (callerReward > 0) {
            (bool ok, ) = payable(msg.sender).call{value: callerReward}("");
            require(ok, "reward xfer failed");
        }

        emit PlanExecuted(planId, p.cyclesExecuted, stackedAmount, msg.sender, callerReward);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function getPlan(uint256 planId)
        external
        view
        returns (
            address owner_,
            uint256 amountPerCycle,
            uint256 cycleSecs,
            uint16 totalCycles,
            uint16 cyclesExecuted,
            uint256 startTime,
            uint256 lastExecutedAt,
            uint8 status
        )
    {
        Plan storage p = _plans[planId];
        return (
            p.owner,
            p.amountPerCycle,
            p.cycleSecs,
            p.totalCycles,
            p.cyclesExecuted,
            p.startTime,
            p.lastExecutedAt,
            uint8(p.status)
        );
    }

    function getPurchases(uint256 planId)
        external
        view
        returns (uint256[] memory blocks, uint256[] memory amounts, uint256[] memory timestamps)
    {
        Purchase[] storage ps = _purchases[planId];
        uint256 n = ps.length;
        blocks = new uint256[](n);
        amounts = new uint256[](n);
        timestamps = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            blocks[i] = ps[i].blockNumber;
            amounts[i] = ps[i].amount;
            timestamps[i] = ps[i].timestamp;
        }
    }

    function getIdleBalance(address user) external view returns (uint256) {
        return _idleBalance[user];
    }

    function getStackedBalance(address user) external view returns (uint256) {
        return _stackedBalance[user];
    }

    function nextExecutionTime(uint256 planId) external view returns (uint256) {
        Plan storage p = _plans[planId];
        if (p.owner == address(0)) return 0;
        if (p.lastExecutedAt == 0) return p.startTime + p.cycleSecs;
        return p.lastExecutedAt + p.cycleSecs;
    }

    function canExecute(uint256 planId) external view returns (bool) {
        Plan storage p = _plans[planId];
        if (p.owner == address(0)) return false;
        if (p.status != PlanStatus.Active) return false;
        if (p.cyclesExecuted >= p.totalCycles) return false;
        if (_idleBalance[p.owner] < p.amountPerCycle) return false;
        if (paused()) return false;
        uint256 dueAt = p.lastExecutedAt == 0
            ? p.startTime + p.cycleSecs
            : p.lastExecutedAt + p.cycleSecs;
        return block.timestamp >= dueAt;
    }

    function getPlansByOwner(address user) external view returns (uint256[] memory) {
        return _plansByOwner[user];
    }

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setPlatformFeeBps(uint16 bps) external onlyOwner {
        require(bps <= 500, "fee too high"); // <= 5%
        platformFeeBps = bps;
        emit PlatformFeeUpdated(bps);
    }

    function setCallerRewardBps(uint16 bps) external onlyOwner {
        require(bps <= 500, "reward too high");
        callerRewardBps = bps;
        emit CallerRewardUpdated(bps);
    }

    function withdrawFees(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "zero to");
        require(amount <= accumulatedFees, "insufficient fees");
        accumulatedFees -= amount;
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "xfer failed");
        emit FeesWithdrawn(to, amount);
    }
}
