// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Hot Chicken 🐔🔥 v3.3
 * @notice Competitive burn game - last holder loses, everyone else wins
 * 
 * @dev v3.3 CHANGES:
 * - LOTTO = 10% of total deposits (5% from winners + 5% from loser)
 * - Seed Vault: Auto-dispenses configured amount each round
 * 
 * TOKENOMICS:
 * - Seed: TAX-FREE - Full seed to chicken holder as consolation
 * - Winners: 11% tax (5% burn + 1% owner + 5% lotto)
 * - Chicken: 21% tax (5% burn + 1% owner + 5% lotto + 10% HZ)
 * - Lotto: 10% of TOTAL deposits, ALL participants eligible
 * 
 * SINGLE FUNCTION: grabChicken() does everything
 */
contract HotChicken is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable eshare;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant BPS = 10000;

    struct Config {
        uint256 baseTimerBlocks;
        uint256 timerDecayBps;
        uint256 timerFloorBlocks;
        uint256 escalationBps;
        uint256 minGrabCost;
        uint256 burnBps;            // 5% burn
        uint256 ownerBps;           // 1% owner
        uint256 lottoBps;           // 5% flat lotto
        uint256 hotZoneBlocks;
        uint256 hotZoneBonusBps;    // 10% HZ bonus
    }

    Config public nextConfig;
    address public feeRecipient;

    uint256 public currentRound;
    bool public roundActive;
    bool public paused;

    address public chickenHolder;
    uint256 public currentMinGrab;
    uint256 public roundEndBlock;

    // Seed Vault System
    uint256 public seedVault;           // Total ESHARE in vault
    uint256 public roundSeedAmount;     // How much to seed each round (default 0.5 ESHARE)
    uint256 public pendingLottoRollover;

    struct RoundData {
        Config config;
        uint256 pot;
        uint256 seed;
        uint256 playerDeposits;
        uint256 hotZoneDeposits;
        uint256 startBlock;
        uint256 endBlock;
        uint256 startTimestamp;
        uint256 endTimestamp;
        uint256 lastGrabBlock;
        uint256 totalGrabs;
        uint256 participantCount;
        address loser;
        uint256 loserDeposits;
        uint256 loserHZDeposits;
        uint256 loserConsolation;
        bool settled;
        uint256 burnedAmount;
        uint256 ownerAmount;
        uint256 actualLottoPot;
        uint256 hotZoneBonusPool;
        uint256 mainPool;
        address lottoWinner;
    }

    mapping(uint256 => RoundData) public rounds;
    mapping(uint256 => address[]) internal _participants;
    mapping(uint256 => mapping(address => uint256)) public deposits;
    mapping(uint256 => mapping(address => uint256)) public hotZoneDeposits;
    mapping(uint256 => mapping(address => uint256)) public grabCount;

    uint256 public totalRounds;
    uint256 public totalBurned;
    uint256 public totalLottoPaid;
    uint256 public totalOwnerRevenue;
    uint256 public totalVolume;
    uint256 public totalSeeded;         // Track total seeded across all rounds

    struct PlayerStats {
        uint256 roundsPlayed;
        uint256 roundsWon;
        uint256 roundsLost;
        uint256 totalDeposited;
        uint256 totalWon;
        uint256 totalLost;
        uint256 lottoWins;
        uint256 lottoWinnings;
        uint256 totalGrabs;
    }

    mapping(address => PlayerStats) public playerStats;

    event RoundStarted(uint256 indexed round, address indexed starter, uint256 grabAmount, uint256 pot, uint256 seed, uint256 endBlock);
    event ChickenGrabbed(uint256 indexed round, address indexed from, address indexed to, uint256 amount, uint256 pot, uint256 nextMinGrab, uint256 blocksLeft, bool isHotZone);
    event HotZoneEntered(uint256 indexed round, uint256 blocksLeft);
    event RoundSettled(uint256 indexed round, address indexed loser, uint256 loserDeposits, uint256 burned, uint256 ownerFee, uint256 lottoPrize, address indexed lottoWinner, uint256 hzBonusPool, uint256 mainPool, uint256 participants);
    event WinnerPaid(uint256 indexed round, address indexed winner, uint256 netDeposit, uint256 mainShare, uint256 hzBonus, uint256 total);
    event LoserConsolation(uint256 indexed round, address indexed loser, uint256 seedAmount, uint256 consolationPaid, uint256 loserDeposits, int256 netResult);
    event LottoPaid(uint256 indexed round, address indexed winner, uint256 amount);
    event SeedVaultDeposit(address indexed depositor, uint256 amount, uint256 newVaultBalance);
    event SeedDispensed(uint256 indexed round, uint256 amount, uint256 remainingVault);
    event RoundRolledOver(uint256 indexed round, uint256 pot, string reason);
    event ConfigUpdated(string param, uint256 oldVal, uint256 newVal);
    event FeeRecipientUpdated(address indexed oldAddr, address indexed newAddr);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event EmergencySettle(uint256 indexed round);
    event EmergencyWithdraw(uint256 amount);

    constructor(address _eshare) Ownable(msg.sender) {
        require(_eshare != address(0), "Invalid token");
        eshare = IERC20(_eshare);
        feeRecipient = msg.sender;

        // Default seed amount: 0.001 ESHARE per round
        roundSeedAmount = 0.001 ether;

        nextConfig = Config({
            baseTimerBlocks: 43200,     // ~24h
            timerDecayBps: 9000,        // 90%
            timerFloorBlocks: 130,      // 4:20
            escalationBps: 11000,       // 110%
            minGrabCost: 0.1 ether,
            burnBps: 500,               // 5%
            ownerBps: 100,              // 1%
            lottoBps: 500,              // 5% flat
            hotZoneBlocks: 150,         // ~5 min
            hotZoneBonusBps: 1000       // 10%
        });
    }

    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MAIN GAME FUNCTION
    // ═══════════════════════════════════════════════════════════════════════

    function grabChicken(uint256 amount) external nonReentrant whenNotPaused {
        if (roundActive && block.number >= roundEndBlock) {
            _settle();
        }

        if (!roundActive) {
            _startNewRound(amount);
            return;
        }

        _grab(amount);
    }

    function _startNewRound(uint256 amount) internal {
        require(amount >= nextConfig.minGrabCost, "Below min");

        eshare.safeTransferFrom(msg.sender, address(this), amount);

        currentRound++;
        totalRounds++;
        roundActive = true;

        RoundData storage rd = rounds[currentRound];
        rd.config = nextConfig;
        
        // Dispense seed from vault (+ any lotto rollover)
        uint256 seedFromVault = 0;
        if (seedVault > 0) {
            seedFromVault = seedVault >= roundSeedAmount ? roundSeedAmount : seedVault;
            seedVault -= seedFromVault;
            totalSeeded += seedFromVault;
            emit SeedDispensed(currentRound, seedFromVault, seedVault);
        }
        
        rd.seed = seedFromVault + pendingLottoRollover;
        rd.pot = rd.seed + amount;
        rd.playerDeposits = amount;
        rd.startBlock = block.number;
        rd.endBlock = block.number + nextConfig.baseTimerBlocks;
        rd.startTimestamp = block.timestamp;
        rd.lastGrabBlock = block.number;
        rd.totalGrabs = 1;
        rd.participantCount = 1;

        chickenHolder = msg.sender;
        currentMinGrab = (amount * nextConfig.escalationBps) / BPS;
        roundEndBlock = rd.endBlock;

        _participants[currentRound].push(msg.sender);
        deposits[currentRound][msg.sender] = amount;
        grabCount[currentRound][msg.sender] = 1;

        uint256 blocksLeft = rd.endBlock - block.number;
        if (blocksLeft <= nextConfig.hotZoneBlocks) {
            rd.hotZoneDeposits = amount;
            hotZoneDeposits[currentRound][msg.sender] = amount;
        }

        playerStats[msg.sender].roundsPlayed++;
        playerStats[msg.sender].totalDeposited += amount;
        playerStats[msg.sender].totalGrabs++;

        pendingLottoRollover = 0;
        totalVolume += amount;

        emit RoundStarted(currentRound, msg.sender, amount, rd.pot, rd.seed, rd.endBlock);
    }

    function _grab(uint256 amount) internal {
        require(msg.sender != chickenHolder, "Already holding");
        require(amount >= currentMinGrab, "Below min");

        eshare.safeTransferFrom(msg.sender, address(this), amount);

        RoundData storage rd = rounds[currentRound];
        Config storage cfg = rd.config;

        uint256 blocksLeft = roundEndBlock - block.number;
        bool wasHotZone = blocksLeft <= cfg.hotZoneBlocks;

        address prevHolder = chickenHolder;
        rd.pot += amount;
        rd.playerDeposits += amount;
        rd.totalGrabs++;

        if (deposits[currentRound][msg.sender] == 0) {
            _participants[currentRound].push(msg.sender);
            rd.participantCount++;
            playerStats[msg.sender].roundsPlayed++;
        }

        deposits[currentRound][msg.sender] += amount;
        grabCount[currentRound][msg.sender]++;

        if (wasHotZone) {
            rd.hotZoneDeposits += amount;
            hotZoneDeposits[currentRound][msg.sender] += amount;
        }

        chickenHolder = msg.sender;
        currentMinGrab = (amount * cfg.escalationBps) / BPS;

        uint256 newDuration = (blocksLeft * cfg.timerDecayBps) / BPS;
        if (newDuration < cfg.timerFloorBlocks) {
            newDuration = cfg.timerFloorBlocks;
        }
        roundEndBlock = block.number + newDuration;
        rd.endBlock = roundEndBlock;
        rd.lastGrabBlock = block.number;

        bool isNowHotZone = newDuration <= cfg.hotZoneBlocks;
        if (isNowHotZone && !wasHotZone) {
            emit HotZoneEntered(currentRound, newDuration);
        }

        playerStats[msg.sender].totalDeposited += amount;
        playerStats[msg.sender].totalGrabs++;
        totalVolume += amount;

        emit ChickenGrabbed(currentRound, prevHolder, msg.sender, amount, rd.pot, currentMinGrab, newDuration, isNowHotZone);
    }

    function _settle() internal {
        RoundData storage rd = rounds[currentRound];
        Config storage cfg = rd.config;

        rd.endTimestamp = block.timestamp;
        rd.loser = chickenHolder;
        rd.settled = true;
        roundActive = false;

        // Single player = rollover
        if (rd.participantCount == 1) {
            // Return seed to vault, player gets their deposit back
            seedVault += rd.seed;
            eshare.safeTransfer(rd.loser, rd.playerDeposits);
            emit RoundRolledOver(currentRound, rd.pot, "single player");
            return;
        }

        rd.loserDeposits = deposits[currentRound][rd.loser];
        rd.loserHZDeposits = hotZoneDeposits[currentRound][rd.loser];

        // Winner deposits (excluding loser)
        uint256 winnerDeposits = rd.playerDeposits - rd.loserDeposits;
        uint256 eligibleHZ = rd.hotZoneDeposits - rd.loserHZDeposits;

        // ═══════════════════════════════════════════════════════════════════
        // TAX CALCULATIONS
        // ═══════════════════════════════════════════════════════════════════

        // Winners pay 11% tax (5% burn + 1% owner + 5% lotto)
        uint256 winnerBurn = (winnerDeposits * cfg.burnBps) / BPS;
        uint256 winnerOwner = (winnerDeposits * cfg.ownerBps) / BPS;
        uint256 winnerLotto = (winnerDeposits * cfg.lottoBps) / BPS;

        // Chicken pays 21% tax (5% burn + 1% owner + 5% lotto + 10% HZ)
        uint256 loserBurn = (rd.loserDeposits * cfg.burnBps) / BPS;
        uint256 loserOwner = (rd.loserDeposits * cfg.ownerBps) / BPS;
        uint256 loserLotto = (rd.loserDeposits * cfg.lottoBps) / BPS;
        uint256 hzBonus = (rd.loserDeposits * cfg.hotZoneBonusBps) / BPS;
        uint256 mainPool = rd.loserDeposits - loserBurn - loserOwner - loserLotto - hzBonus;

        // LOTTO = 10% of total deposits (5% from winners + 5% from loser)
        uint256 lottoPrize = winnerLotto + loserLotto;

        // Cap HZ bonus if no HZ deposits
        if (eligibleHZ == 0) {
            mainPool += hzBonus;
            hzBonus = 0;
        }

        // Seed is TAX-FREE - goes entirely to loser as consolation
        uint256 loserConsolation = rd.seed;
        rd.loserConsolation = loserConsolation;

        // Store totals
        rd.burnedAmount = winnerBurn + loserBurn;
        rd.ownerAmount = winnerOwner + loserOwner;
        rd.actualLottoPot = lottoPrize;
        rd.hotZoneBonusPool = hzBonus;
        rd.mainPool = mainPool;

        // ═══════════════════════════════════════════════════════════════════
        // EXECUTE PAYOUTS
        // ═══════════════════════════════════════════════════════════════════

        // Burn
        uint256 totalBurnAmt = winnerBurn + loserBurn;
        if (totalBurnAmt > 0) {
            eshare.safeTransfer(DEAD, totalBurnAmt);
            totalBurned += totalBurnAmt;
        }

        // Owner fee
        uint256 totalOwnerAmt = winnerOwner + loserOwner;
        if (totalOwnerAmt > 0) {
            eshare.safeTransfer(feeRecipient, totalOwnerAmt);
            totalOwnerRevenue += totalOwnerAmt;
        }

        // Loser consolation (tax-free seed)
        if (loserConsolation > 0) {
            eshare.safeTransfer(rd.loser, loserConsolation);
            int256 netResult = int256(loserConsolation) - int256(rd.loserDeposits);
            emit LoserConsolation(currentRound, rd.loser, rd.seed, loserConsolation, rd.loserDeposits, netResult);
        }

        // Lotto - ALL participants eligible (including loser!)
        address lottoWinner = _selectLottoWinner(rd);
        rd.lottoWinner = lottoWinner;
        if (lottoPrize > 0 && lottoWinner != address(0)) {
            eshare.safeTransfer(lottoWinner, lottoPrize);
            totalLottoPaid += lottoPrize;
            playerStats[lottoWinner].lottoWins++;
            playerStats[lottoWinner].lottoWinnings += lottoPrize;
            emit LottoPaid(currentRound, lottoWinner, lottoPrize);
        }

        // Pay winners (excluding loser)
        address[] storage participants = _participants[currentRound];
        for (uint256 i = 0; i < participants.length; i++) {
            address player = participants[i];
            if (player == rd.loser) continue;

            uint256 userDeposits = deposits[currentRound][player];
            uint256 userHZDeposits = hotZoneDeposits[currentRound][player];

            // Their deposit returned minus 11% tax (5% burn + 1% owner + 5% lotto)
            uint256 userNet = userDeposits - (userDeposits * cfg.burnBps) / BPS - (userDeposits * cfg.ownerBps) / BPS - (userDeposits * cfg.lottoBps) / BPS;

            // Main pool share (proportional to deposits)
            uint256 mainShare = 0;
            if (winnerDeposits > 0 && mainPool > 0) {
                mainShare = (mainPool * userDeposits) / winnerDeposits;
            }

            // HZ bonus share
            uint256 hzShare = 0;
            if (eligibleHZ > 0 && hzBonus > 0 && userHZDeposits > 0) {
                hzShare = (hzBonus * userHZDeposits) / eligibleHZ;
            }

            uint256 totalPayout = userNet + mainShare + hzShare;
            
            if (totalPayout > 0) {
                eshare.safeTransfer(player, totalPayout);
                playerStats[player].totalWon += (mainShare + hzShare);
                playerStats[player].roundsWon++;
            }

            emit WinnerPaid(currentRound, player, userNet, mainShare, hzShare, totalPayout);
        }

        // Loser stats
        playerStats[rd.loser].roundsLost++;
        if (rd.loserDeposits > loserConsolation) {
            playerStats[rd.loser].totalLost += (rd.loserDeposits - loserConsolation);
        }

        emit RoundSettled(currentRound, rd.loser, rd.loserDeposits, rd.burnedAmount, rd.ownerAmount, lottoPrize, lottoWinner, hzBonus, mainPool, rd.participantCount);
    }

    function _selectLottoWinner(RoundData storage rd) internal view returns (address) {
        address[] storage participants = _participants[currentRound];
        if (participants.length == 0) return address(0);
        
        bytes32 grabBlockHash = blockhash(rd.lastGrabBlock);
        if (grabBlockHash == 0) {
            grabBlockHash = blockhash(block.number - 1);
        }
        
        uint256 randomness = uint256(keccak256(abi.encodePacked(grabBlockHash, currentRound, rd.loser)));
        return participants[randomness % participants.length];
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PUBLIC FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit ESHARE into the seed vault (anyone can call)
     * @param amount Amount to deposit into vault
     */
    function depositSeed(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        eshare.safeTransferFrom(msg.sender, address(this), amount);
        seedVault += amount;
        emit SeedVaultDeposit(msg.sender, amount, seedVault);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // OWNER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function emergencyPause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function emergencyUnpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function emergencySettle() external onlyOwner {
        require(paused, "Not paused");
        require(roundActive, "No round");
        _settle();
        emit EmergencySettle(currentRound);
    }

    function emergencyWithdraw() external onlyOwner {
        require(paused, "Not paused");
        require(!roundActive, "Round active");
        uint256 bal = eshare.balanceOf(address(this));
        if (bal > 0) {
            eshare.safeTransfer(feeRecipient, bal);
        }
        emit EmergencyWithdraw(bal);
    }

    function setFeeRecipient(address addr) external onlyOwner {
        require(addr != address(0), "Zero addr");
        emit FeeRecipientUpdated(feeRecipient, addr);
        feeRecipient = addr;
    }

    /**
     * @notice Set how much ESHARE seeds each new round
     * @param amount Amount in wei (0.001 to 100 ESHARE)
     */
    function setRoundSeedAmount(uint256 amount) external onlyOwner {
        require(amount >= 0.001 ether && amount <= 100 ether, "0.001-100");
        emit ConfigUpdated("roundSeedAmount", roundSeedAmount, amount);
        roundSeedAmount = amount;
    }

    function setBaseTimerBlocks(uint256 val) external onlyOwner {
        require(val >= 1800 && val <= 302400, "1h-7d");
        emit ConfigUpdated("baseTimerBlocks", nextConfig.baseTimerBlocks, val);
        nextConfig.baseTimerBlocks = val;
    }

    function setTimerDecayBps(uint256 val) external onlyOwner {
        require(val >= 5000 && val <= 9500, "50-95%");
        emit ConfigUpdated("timerDecayBps", nextConfig.timerDecayBps, val);
        nextConfig.timerDecayBps = val;
    }

    function setTimerFloorBlocks(uint256 val) external onlyOwner {
        require(val >= 30 && val <= 1800, "1-60min");
        emit ConfigUpdated("timerFloorBlocks", nextConfig.timerFloorBlocks, val);
        nextConfig.timerFloorBlocks = val;
    }

    function setEscalationBps(uint256 val) external onlyOwner {
        require(val >= 10100 && val <= 15000, "101-150%");
        emit ConfigUpdated("escalationBps", nextConfig.escalationBps, val);
        nextConfig.escalationBps = val;
    }

    function setMinGrabCost(uint256 val) external onlyOwner {
        require(val >= 0.001 ether && val <= 5 ether, "0.001-5");
        emit ConfigUpdated("minGrabCost", nextConfig.minGrabCost, val);
        nextConfig.minGrabCost = val;
    }

    function setBurnBps(uint256 val) external onlyOwner {
        require(val <= 1000, "Max 10%");
        emit ConfigUpdated("burnBps", nextConfig.burnBps, val);
        nextConfig.burnBps = val;
    }

    function setOwnerBps(uint256 val) external onlyOwner {
        require(val <= 500, "Max 5%");
        emit ConfigUpdated("ownerBps", nextConfig.ownerBps, val);
        nextConfig.ownerBps = val;
    }

    function setLottoBps(uint256 val) external onlyOwner {
        require(val <= 1000, "Max 10%");
        emit ConfigUpdated("lottoBps", nextConfig.lottoBps, val);
        nextConfig.lottoBps = val;
    }

    function setHotZoneBlocks(uint256 val) external onlyOwner {
        require(val >= 30 && val <= 900, "1-30min");
        emit ConfigUpdated("hotZoneBlocks", nextConfig.hotZoneBlocks, val);
        nextConfig.hotZoneBlocks = val;
    }

    function setHotZoneBonusBps(uint256 val) external onlyOwner {
        require(val <= 2000, "Max 20%");
        emit ConfigUpdated("hotZoneBonusBps", nextConfig.hotZoneBonusBps, val);
        nextConfig.hotZoneBonusBps = val;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function getConfig() external view returns (Config memory) {
        return nextConfig;
    }

    function getRoundConfig(uint256 round) external view returns (Config memory) {
        return rounds[round].config;
    }

    function getParticipants(uint256 round) external view returns (address[] memory) {
        return _participants[round];
    }

    function getPlayerStats(address player) external view returns (PlayerStats memory) {
        return playerStats[player];
    }

    function getSeedVaultInfo() external view returns (
        uint256 vaultBalance,
        uint256 amountPerRound,
        uint256 roundsRemaining
    ) {
        vaultBalance = seedVault;
        amountPerRound = roundSeedAmount;
        roundsRemaining = roundSeedAmount > 0 ? seedVault / roundSeedAmount : 0;
    }

    function getCurrentRound() external view returns (
        uint256 round,
        uint256 pot,
        address holder,
        uint256 minGrab,
        uint256 blocksLeft,
        uint256 participants,
        uint256 grabs,
        bool isHotZone,
        uint256 hzDeposits
    ) {
        round = currentRound;
        if (!roundActive) {
            return (round, 0, address(0), nextConfig.minGrabCost, 0, 0, 0, false, 0);
        }
        
        RoundData storage rd = rounds[currentRound];
        pot = rd.pot;
        holder = chickenHolder;
        minGrab = currentMinGrab;
        blocksLeft = block.number >= roundEndBlock ? 0 : roundEndBlock - block.number;
        participants = rd.participantCount;
        grabs = rd.totalGrabs;
        isHotZone = blocksLeft <= rd.config.hotZoneBlocks;
        hzDeposits = rd.hotZoneDeposits;
    }

    function getRoundInfo(uint256 round) external view returns (
        uint256 pot,
        uint256 seed,
        uint256 playerDeps,
        uint256 hzDeps,
        address loser,
        uint256 loserDeps,
        bool settled,
        uint256 burned,
        uint256 lottoPrize,
        address lottoWinner,
        uint256 hzBonus,
        uint256 mainPool
    ) {
        RoundData storage rd = rounds[round];
        return (rd.pot, rd.seed, rd.playerDeposits, rd.hotZoneDeposits, rd.loser, rd.loserDeposits, rd.settled, rd.burnedAmount, rd.actualLottoPot, rd.lottoWinner, rd.hotZoneBonusPool, rd.mainPool);
    }

    function getTimeLeft() external view returns (uint256 blocks, uint256 secs, bool isHZ) {
        if (!roundActive || block.number >= roundEndBlock) {
            return (0, 0, false);
        }
        blocks = roundEndBlock - block.number;
        secs = blocks * 2;
        isHZ = blocks <= rounds[currentRound].config.hotZoneBlocks;
    }

    function getGlobalStats() external view returns (
        uint256 rounds_,
        uint256 burned,
        uint256 lottoPaid,
        uint256 ownerRev,
        uint256 volume,
        bool active,
        uint256 seeded
    ) {
        return (totalRounds, totalBurned, totalLottoPaid, totalOwnerRevenue, totalVolume, roundActive, totalSeeded);
    }

    function getPlayerRound(uint256 round, address player) external view returns (
        uint256 deps,
        uint256 hzDeps,
        uint256 grabs,
        bool isLoser
    ) {
        return (deposits[round][player], hotZoneDeposits[round][player], grabCount[round][player], rounds[round].loser == player);
    }

    function needsSettle() external view returns (bool) {
        return roundActive && block.number >= roundEndBlock;
    }
}
