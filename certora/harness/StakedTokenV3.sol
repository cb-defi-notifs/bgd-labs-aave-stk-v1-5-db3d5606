// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.8.0;

// most imports are only here to force import order for better (i.e smaller) diff on flattening
import {Context} from '../../src/lib/Context.sol';
import {IERC20} from '../../src/interfaces/IERC20.sol';
import {ERC20} from '../../src/lib/ERC20.sol';
import {ITransferHook} from '../../src/interfaces/ITransferHook.sol';
import {DistributionTypes} from '../../src/lib/DistributionTypes.sol';
import {Address} from '../../src/lib/Address.sol';
import {SafeERC20} from '../../src/lib/SafeERC20.sol';
import {VersionedInitializable} from '../../src/utils/VersionedInitializable.sol';
import {IAaveDistributionManager} from '../../src/interfaces/IAaveDistributionManager.sol';
import {AaveDistributionManager} from './AaveDistributionManager.sol';
import {IGovernancePowerDelegationToken} from '../../src/interfaces/IGovernancePowerDelegationToken.sol';
import {GovernancePowerDelegationERC20} from '../../src/lib/GovernancePowerDelegationERC20.sol';
import {GovernancePowerWithSnapshot} from '../../src/lib/GovernancePowerWithSnapshot.sol';
import {IERC20WithPermit} from '../../src/interfaces/IERC20WithPermit.sol';
import {IStakedTokenV2} from '../../src/interfaces/IStakedTokenV2.sol';
import {StakedTokenV2} from './StakedTokenV2.sol';
import {IStakedTokenV3} from '../../src/interfaces/IStakedTokenV3.sol';
import {PercentageMath} from '../../src/lib/PercentageMath.sol';
import {RoleManager} from '../../src/utils/RoleManager.sol';

/**
 * @title StakedTokenV3
 * @notice Contract to stake Aave token, tokenize the position and get rewards, inheriting from a distribution manager contract
 * @author BGD Labs
 */
contract StakedTokenV3 is StakedTokenV2, IStakedTokenV3, RoleManager {
  using SafeERC20 for IERC20;
  using PercentageMath for uint256;

  uint256 public constant SLASH_ADMIN_ROLE = 0;
  uint256 public constant COOLDOWN_ADMIN_ROLE = 1;
  uint256 public constant CLAIM_HELPER_ROLE = 2;
  uint128 public constant INITIAL_EXCHANGE_RATE = 1e18;
  uint256 public constant TOKEN_UNIT = 1e18;

  // @notice Seconds between starting cooldown and being able to withdraw
  uint256 internal _cooldownSeconds;
  // @notice The maximum amount of funds that can be slashed at any given time
  uint256 internal _maxSlashablePercentage;
  // @notice Mirror of latest snapshot value for cheaper access
  uint128 internal _currentExchangeRate;
  // @notice Flag determining if there's an ongoing slashing event that needs to be settled
  bool public inPostSlashingPeriod;

  modifier onlySlashingAdmin() {
    require(
      msg.sender == getAdmin(SLASH_ADMIN_ROLE),
      'CALLER_NOT_SLASHING_ADMIN'
    );
    _;
  }

  modifier onlyCooldownAdmin() {
    require(
      msg.sender == getAdmin(COOLDOWN_ADMIN_ROLE),
      'CALLER_NOT_COOLDOWN_ADMIN'
    );
    _;
  }

  modifier onlyClaimHelper() {
    require(
      msg.sender == getAdmin(CLAIM_HELPER_ROLE),
      'CALLER_NOT_CLAIM_HELPER'
    );
    _;
  }

  constructor(
    IERC20 stakedToken,
    IERC20 rewardToken,
    uint256 unstakeWindow,
    address rewardsVault,
    address emissionManager,
    uint128 distributionDuration
  )
    StakedTokenV2(
      stakedToken,
      rewardToken,
      unstakeWindow,
      rewardsVault,
      emissionManager,
      distributionDuration
    )
  /*solhint-disable no-empty-blocks*/
  {}

  /**
   * @dev returns the revision of the implementation contract
   * @return The revision
   */
  /*solhint-disable func-name-mixedcase */
  function REVISION() public pure virtual override returns (uint256) {
    return 3;
  }

  /**
   * @dev returns the revision of the implementation contract
   * @return The revision
   */
  function getRevision() internal pure virtual override returns (uint256) {
    return REVISION();
  }

  /**
   * @dev Called by the proxy contract
   */
  function initialize(
    address slashingAdmin,
    address cooldownPauseAdmin,
    address claimHelper,
    uint256 maxSlashablePercentage,
    uint256 cooldownSeconds
  ) external virtual initializer {
    _initialize(
      slashingAdmin,
      cooldownPauseAdmin,
      claimHelper,
      maxSlashablePercentage,
      cooldownSeconds
    );
  }

  function _initialize(
    address slashingAdmin,
    address cooldownPauseAdmin,
    address claimHelper,
    uint256 maxSlashablePercentage,
    uint256 cooldownSeconds
  ) internal {
    InitAdmin[] memory initAdmins = new InitAdmin[](3);
    initAdmins[0] = InitAdmin(SLASH_ADMIN_ROLE, slashingAdmin);
    initAdmins[1] = InitAdmin(COOLDOWN_ADMIN_ROLE, cooldownPauseAdmin);
    initAdmins[2] = InitAdmin(CLAIM_HELPER_ROLE, claimHelper);

    _initAdmins(initAdmins);

    _setMaxSlashablePercentage(maxSlashablePercentage);
    _setCooldownSeconds(cooldownSeconds);
    _updateExchangeRate(INITIAL_EXCHANGE_RATE);
  }

  /// @inheritdoc IStakedTokenV3
  function previewStake(uint256 assets) public override view returns (uint256) {
    return (assets * _currentExchangeRate) / TOKEN_UNIT;
  }

  /// @inheritdoc IStakedTokenV2
  function stake(address to, uint256 amount)
    external
    override(IStakedTokenV2, StakedTokenV2)
  {
    _stake(msg.sender, to, amount);
  }

  /// @inheritdoc IStakedTokenV3
  function stakeWithPermit(
    address from,
    address to,
    uint256 amount,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external override {
    IERC20WithPermit(address(STAKED_TOKEN)).permit(
      from,
      address(this),
      amount,
      deadline,
      v,
      r,
      s
    );
    _stake(from, to, amount);
  }

  /// @inheritdoc IStakedTokenV2
  function redeem(address to, uint256 amount)
    external
    override(IStakedTokenV2, StakedTokenV2)
  {
    _redeem(msg.sender, to, amount);
  }

  /// @inheritdoc IStakedTokenV3
  function redeemOnBehalf(
    address from,
    address to,
    uint256 amount
  ) external override onlyClaimHelper {
    _redeem(from, to, amount);
  }

  /// @inheritdoc IStakedTokenV2
  function claimRewards(address to, uint256 amount)
    external
    override(IStakedTokenV2, StakedTokenV2)
  {
    _claimRewards(msg.sender, to, amount);
  }

  /// @inheritdoc IStakedTokenV3
  function claimRewardsOnBehalf(
    address from,
    address to,
    uint256 amount
  ) external override onlyClaimHelper returns (uint256) {
    return _claimRewards(from, to, amount);
  }

  /// @inheritdoc IStakedTokenV3
  function claimRewardsAndStake(address to, uint256 amount)
    external
    override
    returns (uint256)
  {
    return _claimRewardsAndStakeOnBehalf(msg.sender, to, amount);
  }

  /// @inheritdoc IStakedTokenV3
  function claimRewardsAndStakeOnBehalf(
    address from,
    address to,
    uint256 amount
  ) external override onlyClaimHelper returns (uint256) {
    return _claimRewardsAndStakeOnBehalf(from, to, amount);
  }

  /// @inheritdoc IStakedTokenV3
  function claimRewardsAndRedeem(
    address to,
    uint256 claimAmount,
    uint256 redeemAmount
  ) external override {
    _claimRewards(msg.sender, to, claimAmount);
    _redeem(msg.sender, to, redeemAmount);
  }

  /// @inheritdoc IStakedTokenV3
  function claimRewardsAndRedeemOnBehalf(
    address from,
    address to,
    uint256 claimAmount,
    uint256 redeemAmount
  ) external override onlyClaimHelper {
    _claimRewards(from, to, claimAmount);
    _redeem(from, to, redeemAmount);
  }

  /// @inheritdoc IStakedTokenV3
  function getExchangeRate() public view override returns (uint128) {
    return _currentExchangeRate;
  }

  /// @inheritdoc IStakedTokenV3
  function previewRedeem(uint256 shares)
    public
    view
    override
    returns (uint256)
  {
    return (TOKEN_UNIT * shares) / _currentExchangeRate;
  }

  /// @inheritdoc IStakedTokenV3
  function slash(address destination, uint256 amount)
    external
    override
    onlySlashingAdmin
    returns (uint256)
  {
    require(!inPostSlashingPeriod, 'PREVIOUS_SLASHING_NOT_SETTLED');
    uint256 currentShares = totalSupply();
    uint256 balance = previewRedeem(currentShares);

    uint256 maxSlashable = balance.percentMul(_maxSlashablePercentage);

    if (amount > maxSlashable) {
      amount = maxSlashable;
    }

    inPostSlashingPeriod = true;
    _updateExchangeRate(_getExchangeRate(balance - amount, currentShares));

    STAKED_TOKEN.safeTransfer(destination, amount);

    emit Slashed(destination, amount);
    return amount;
  }

  /// @inheritdoc IStakedTokenV3
  function returnFunds(uint256 amount) external override {
    uint256 currentShares = totalSupply();
    uint256 assets = previewRedeem(currentShares);
    _updateExchangeRate(_getExchangeRate(assets + amount, currentShares));

    STAKED_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
    emit FundsReturned(amount);
  }

  /// @inheritdoc IStakedTokenV3
  function settleSlashing() external override onlySlashingAdmin {
    inPostSlashingPeriod = false;
    emit SlashingSettled();
  }

  /// @inheritdoc IStakedTokenV3
  function setMaxSlashablePercentage(uint256 percentage)
    external
    override
    onlySlashingAdmin
  {
    _setMaxSlashablePercentage(percentage);
  }

  /// @inheritdoc IStakedTokenV3
  function getMaxSlashablePercentage()
    external
    view
    override
    returns (uint256)
  {
    return _maxSlashablePercentage;
  }

  /// @inheritdoc IStakedTokenV3
  function setCooldownSeconds(uint256 cooldownSeconds)
    external
    override
    onlyCooldownAdmin
  {
    _setCooldownSeconds(cooldownSeconds);
  }

  /// @inheritdoc IStakedTokenV3
  function getCooldownSeconds() external override view returns (uint256) {
    return _cooldownSeconds;
  }

  /*solhint-disable not-rely-on-time*/
  /// @inheritdoc IStakedTokenV2
  function getNextCooldownTimestamp(
    uint256 fromCooldownTimestamp,
    uint256 amountToReceive,
    address toAddress,
    uint256 toBalance
  ) public view override(IStakedTokenV2, StakedTokenV2) returns (uint256) {
    uint256 toCooldownTimestamp = stakersCooldowns[toAddress];
    if (toCooldownTimestamp == 0) {
      return 0;
    }

    uint256 minimalValidCooldownTimestamp = block.timestamp -
      _cooldownSeconds -
      UNSTAKE_WINDOW;

    if (minimalValidCooldownTimestamp > toCooldownTimestamp) {
      toCooldownTimestamp = 0;
    } else {
      uint256 adjustedFromCooldownTimestamp = (minimalValidCooldownTimestamp >
        fromCooldownTimestamp)
        ? block.timestamp
        : fromCooldownTimestamp;

      if (adjustedFromCooldownTimestamp < toCooldownTimestamp) {
        return toCooldownTimestamp;
      } else {
        toCooldownTimestamp =
          ((amountToReceive * adjustedFromCooldownTimestamp) +
            (toBalance * toCooldownTimestamp)) /
          (amountToReceive + toBalance);
      }
    }
    return toCooldownTimestamp;
  }

  /**
   * @dev sets the max slashable percentage
   * @param percentage must be strictly lower 100% as otherwise the exchange rate calculation would result in 0 division
   */
  function _setMaxSlashablePercentage(uint256 percentage) internal {
    require(
      percentage < PercentageMath.PERCENTAGE_FACTOR,
      'INVALID_SLASHING_PERCENTAGE'
    );

    _maxSlashablePercentage = percentage;
    emit MaxSlashablePercentageChanged(percentage);
  }

  /**
   * @dev sets the cooldown seconds
   * @param cooldownSeconds the new amount of cooldown seconds
   */
  function _setCooldownSeconds(uint256 cooldownSeconds) internal {
    _cooldownSeconds = cooldownSeconds;
    emit CooldownSecondsChanged(cooldownSeconds);
  }

  /**
   * @dev claims the rewards for a specified address to a specified address
   * @param from The address of the from from which to claim
   * @param to Address to receive the rewards
   * @param amount Amount to claim
   * @return amount claimed
   */
  function _claimRewards(
    address from,
    address to,
    uint256 amount
  ) internal returns (uint256) {
    require(amount != 0, 'INVALID_ZERO_AMOUNT');
    uint256 newTotalRewards = _updateCurrentUnclaimedRewards(
      from,
      balanceOf(from),
      false
    );

    uint256 amountToClaim = (amount > newTotalRewards)
      ? newTotalRewards
      : amount;

    stakerRewardsToClaim[from] = newTotalRewards - amountToClaim;
    REWARD_TOKEN.safeTransferFrom(REWARDS_VAULT, to, amountToClaim);
    emit RewardsClaimed(from, to, amountToClaim);
    return amountToClaim;
  }

  /**
   * @dev Claims an `amount` of `REWARD_TOKEN` and restakes. Only the claim helper contract is allowed to call this function
   * @param from The address of the from from which to claim
   * @param to Address to stake to
   * @param amount Amount to claim
   * @return amount claimed
   */
  function _claimRewardsAndStakeOnBehalf(
    address from,
    address to,
    uint256 amount
  ) internal returns (uint256) {
    require(REWARD_TOKEN == STAKED_TOKEN, 'REWARD_TOKEN_IS_NOT_STAKED_TOKEN');

    uint256 userUpdatedRewards = _updateCurrentUnclaimedRewards(
      from,
      balanceOf(from),
      true
    );
    uint256 amountToClaim = (amount > userUpdatedRewards)
      ? userUpdatedRewards
      : amount;

    if (amountToClaim != 0) {
      _claimRewards(from, address(this), amountToClaim);
      _stake(address(this), to, amountToClaim);
    }

    return amountToClaim;
  }

  /**
   * @dev Allows staking a specified amount of STAKED_TOKEN
   * @param to The address to receiving the shares
   * @param amount The amount of assets to be staked
   */
  function _stake(
    address from,
    address to,
    uint256 amount
  ) internal {
    require(!inPostSlashingPeriod, 'SLASHING_ONGOING');
    require(amount != 0, 'INVALID_ZERO_AMOUNT');

    uint256 balanceOfTo = balanceOf(to);

    uint256 accruedRewards = _updateUserAssetInternal(
      to,
      address(this),
      balanceOfTo,
      totalSupply()
    );

    if (accruedRewards != 0) {
      stakerRewardsToClaim[to] = stakerRewardsToClaim[to] + accruedRewards;
      emit RewardsAccrued(to, accruedRewards);
    }

    stakersCooldowns[to] = getNextCooldownTimestamp(0, amount, to, balanceOfTo);

    uint256 sharesToMint = previewStake(amount);

    STAKED_TOKEN.safeTransferFrom(from, address(this), amount);

    _mint(to, sharesToMint);

    emit Staked(from, to, amount, sharesToMint);
  }

  /**
   * @dev Redeems staked tokens, and stop earning rewards
   * @param from Address to redeem from
   * @param to Address to redeem to
   * @param amount Amount to redeem
   */
  function _redeem(
    address from,
    address to,
    uint256 amount
  ) internal {
    require(amount != 0, 'INVALID_ZERO_AMOUNT');
    //solium-disable-next-line
    uint256 cooldownStartTimestamp = stakersCooldowns[from];

    if (!inPostSlashingPeriod) {
      require(
        (block.timestamp > cooldownStartTimestamp + _cooldownSeconds),
        'INSUFFICIENT_COOLDOWN'
      );
      require(
        (block.timestamp - (cooldownStartTimestamp + _cooldownSeconds) <=
          UNSTAKE_WINDOW),
        'UNSTAKE_WINDOW_FINISHED'
      );
    }
    uint256 balanceOfFrom = balanceOf(from);

    uint256 amountToRedeem = (amount > balanceOfFrom) ? balanceOfFrom : amount;

    _updateCurrentUnclaimedRewards(from, balanceOfFrom, true);

    uint256 underlyingToRedeem = (amountToRedeem * TOKEN_UNIT) /
      _currentExchangeRate;

    _burn(from, amountToRedeem);

    if (balanceOfFrom - amountToRedeem == 0) {
      stakersCooldowns[from] = 0;
    }

    IERC20(STAKED_TOKEN).safeTransfer(to, underlyingToRedeem);

    emit Redeem(from, to, underlyingToRedeem, amountToRedeem);
  }

  /**
   * @dev Updates the exchangeRate and emits events accordingly
   * @param newExchangeRate the new exchange rate
   */
  function _updateExchangeRate(uint128 newExchangeRate) internal virtual {
    _currentExchangeRate = newExchangeRate;
    emit ExchangeRateChanged(newExchangeRate);
  }

  /**
   * @dev calculates the exchange rate based on totalAssets and totalShares
   * @dev always rounds up to ensure 100% backing of shares by rounding in favor of the contract
   * @param totalAssets The total amount of assets staked
   * @param totalShares The total amount of shares
   * @return exchangeRate as 18 decimal precision uint128
   */
  function _getExchangeRate(uint256 totalAssets, uint256 totalShares)
    internal
    pure
    returns (uint128)
  {
    return uint128(((totalShares * TOKEN_UNIT) + TOKEN_UNIT) / totalAssets);
  }

}