# @version 0.2.12
# @author skozin <info@lido.fi>
# @licence MIT
from vyper.interfaces import ERC20


interface BridgeConnector:
    def forward_beth(terra_address: bytes32, amount: uint256, extra_data: Bytes[1024]): nonpayable
    def forward_ust(terra_address: bytes32, amount: uint256, extra_data: Bytes[1024]): nonpayable
    def adjust_amount(amount: uint256, decimals: uint256) -> uint256: view


interface RewardsLiquidator:
    def liquidate(ust_recipient: address) -> uint256: nonpayable


interface InsuranceConnector:
    def total_shares_burnt() -> uint256: view


interface Mintable:
    def mint(owner: address, amount: uint256): nonpayable
    def burn(owner: address, amount: uint256): nonpayable


interface Lido:
    def submit(referral: address) -> uint256: payable
    def totalSupply() -> uint256: view
    def getTotalShares() -> uint256: view
    def sharesOf(owner: address) -> uint256: view
    def getPooledEthByShares(shares_amount: uint256) -> uint256: view


event Deposited:
    sender: indexed(address)
    amount: uint256
    terra_address: bytes32
    beth_amount_received: uint256


event Withdrawn:
    recipient: indexed(address)
    amount: uint256
    steth_amount_received: uint256


event Refunded:
    recipient: indexed(address)
    beth_amount: uint256
    steth_amount: uint256
    comment: String[1024]


event RefundedBethBurned:
    beth_amount: uint256


event RewardsCollected:
    steth_amount: uint256
    ust_amount: uint256


event AdminChanged:
    new_admin: address


event EmergencyAdminChanged:
    new_emergency_admin: address


event BridgeConnectorUpdated:
    bridge_connector: address


event RewardsLiquidatorUpdated:
    rewards_liquidator: address


event InsuranceConnectorUpdated:
    insurance_connector: address


event LiquidationConfigUpdated:
    liquidations_admin: address
    no_liquidation_interval: uint256
    restricted_liquidation_interval: uint256


event AnchorRewardsDistributorUpdated:
    anchor_rewards_distributor: bytes32


event VersionIncremented:
    new_version: uint256


event OperationsStopped:
    pass


event OperationsResumed:
    pass


BETH_DECIMALS: constant(uint256) = 18

# A constant used in `_can_deposit_or_withdraw` when comparing Lido share prices.
#
# Due to integer rounding, Lido.getPooledEthByShares(10**18) may return slightly
# different numbers even if there were no oracle reports between two calls. This
# might happen if someone submits ETH before the second call. It can be mathematically
# proven that this difference won't be more than 10 wei given that Lido holds at least
# 0.1 ETH and the share price is of the same order of magnitude as the amount of ETH
# held. Both of these conditions are true if Lido operates normally—and if it doesn't,
# it's desirable for AnchorVault operations to be suspended. See:
#
# https://github.com/lidofinance/lido-dao/blob/eb33eb8/contracts/0.4.24/Lido.sol#L445
# https://github.com/lidofinance/lido-dao/blob/eb33eb8/contracts/0.4.24/StETH.sol#L288
#
STETH_SHARE_PRICE_MAX_ERROR: constant(uint256) = 10

# Aragon Agent contract of the Lido DAO
LIDO_DAO_AGENT: constant(address) = 0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c

# WARNING: since this contract is behind a proxy, don't change the order of the variables
# and don't remove variables during the code upgrades. You can only append new variables
# to the end of the list.

admin: public(address)

beth_token: public(address)
steth_token: public(address)
bridge_connector: public(address)
rewards_liquidator: public(address)
insurance_connector: public(address)
anchor_rewards_distributor: public(bytes32)

liquidations_admin: public(address)
no_liquidation_interval: public(uint256)
restricted_liquidation_interval: public(uint256)

last_liquidation_time: public(uint256)
last_liquidation_share_price: public(uint256)
last_liquidation_shares_burnt: public(uint256)

# The contract version. Used to mark backwards-incompatible changes to the contract
# logic, including installing delegates with an incompatible API. Can be changed both
# in `_initialize_vX` after implementation code changes and by calling `bump_version`
# after installing a new delegate.
#
# The following functions revert unless the value of the `_expected_version` argument
# matches the one stored in this state variable:
#
# * `deposit`
# * `withdraw`
#
# It's recommended for any external code interacting with this contract, both onchain
# and offchain, to have the current version set as a configurable parameter to make
# sure any incompatible change to the contract logic won't produce unexpected results,
# reverting the transactions instead until the compatibility is manually checked and
# the configured version is updated.
#
version: public(uint256)

emergency_admin: public(address)
operations_allowed: public(bool)

total_beth_refunded: public(uint256)


@internal
def _assert_version(_expected_version: uint256):
    assert _expected_version == self.version, "unexpected contract version"


@internal
def _assert_not_stopped():
    assert self.operations_allowed, "contract stopped"


@internal
def _assert_admin(addr: address):
    assert addr == self.admin # dev: unauthorized


@internal
def _assert_dao_governance(addr: address):
    assert addr == LIDO_DAO_AGENT # dev: unauthorized

@internal
def _initialize_v4():
    self.version = 4
    log VersionIncremented(4)


@external
def initialize(beth_token: address, steth_token: address, admin: address, emergency_admin: address):
    assert self.beth_token == ZERO_ADDRESS # dev: already initialized
    assert self.version == 0 # dev: already initialized

    assert beth_token != ZERO_ADDRESS # dev: invalid bETH address
    assert steth_token != ZERO_ADDRESS # dev: invalid stETH address

    assert ERC20(beth_token).totalSupply() == 0 # dev: non-zero bETH total supply

    self.beth_token = beth_token
    self.steth_token = steth_token
    # we're explicitly allowing zero admin address for ossification
    self.admin = admin
    self.last_liquidation_share_price = Lido(steth_token).getPooledEthByShares(10**18)

    ## version 3
    self.emergency_admin = emergency_admin
    log EmergencyAdminChanged(emergency_admin)
    self.version = 3
    log VersionIncremented(3)

    self._initialize_v4()

    log AdminChanged(admin)


@external
def petrify_impl():
    """
    @dev Prevents initialization of an implementation sitting behind a proxy.
    """
    assert self.version == 0 # dev: already initialized
    self.version = MAX_UINT256


@external
def emergency_stop():
    """
    @dev Performs emergency stop of the contract. Can only be called
    by the current emergency admin or by the current admin.

    While contract is in the stopped state, the following functions revert:

    * `submit`
    * `withdraw`
    * `collect_rewards`

    See `resume`, `set_emergency_admin`.
    """
    assert msg.sender == self.emergency_admin or msg.sender == self.admin # dev: unauthorized
    self._assert_not_stopped()
    self.operations_allowed = False
    log OperationsStopped()


@external
def resume():
    """
    @dev Resumes normal operations of the contract. Can only be called
    by the Lido DAO governance contract.

    See `emergency_stop`.
    """
    self._assert_dao_governance(msg.sender)
    assert not self.operations_allowed # dev: not stopped
    self.operations_allowed = True
    log OperationsResumed()


@external
def change_admin(new_admin: address):
    """
    @dev Changes the admin address. Can only be called by the current admin address.

    Setting the admin to zero ossifies the contract, i.e. makes it irreversibly non-administrable.
    """
    self._assert_admin(msg.sender)
    # we're explicitly allowing zero admin address for ossification
    self.admin = new_admin
    log AdminChanged(new_admin)


@external
def set_emergency_admin(new_emergency_admin: address):
    """
    @dev Sets the address allowed to perform an emergency stop and having no other privileges.

    Can only be called by the Lido DAO governance contract.

    See `emergency_stop`, `resume`.
    """
    self._assert_dao_governance(msg.sender)
    # we're explicitly allowing zero address
    self.emergency_admin = new_emergency_admin
    log EmergencyAdminChanged(new_emergency_admin)


@external
def bump_version():
    """
    @dev Increments contract version. Can only be called by the current admin address.

    Due to the usage of replaceable delegates, contract version cannot be compiled to
    the AnchorVault implementation as a constant. Instead, the governance should call
    this function when backwards-incompatible changes are made to the contract or its
    delegates.
    """
    self._assert_admin(msg.sender)
    new_version: uint256 = self.version + 1
    self.version = new_version
    log VersionIncremented(new_version)


@internal
def _set_bridge_connector(_bridge_connector: address):
    self.bridge_connector = _bridge_connector
    log BridgeConnectorUpdated(_bridge_connector)


@external
def set_bridge_connector(_bridge_connector: address):
    """
    @dev Sets the bridge connector contract: an adapter contract for communicating
         with the Terra bridge.

    Can only be called by the current admin address.
    """
    self._assert_admin(msg.sender)
    self._set_bridge_connector(_bridge_connector)


@internal
def _set_rewards_liquidator(_rewards_liquidator: address):
    self.rewards_liquidator = _rewards_liquidator # dev: unauthorized
    log RewardsLiquidatorUpdated(_rewards_liquidator)


@external
def set_rewards_liquidator(_rewards_liquidator: address):
    """
    @dev Sets the rewards liquidator contract: a contract for selling stETH rewards to UST.

    Can only be called by the current admin address.
    """
    self._assert_admin(msg.sender)
    self._set_rewards_liquidator(_rewards_liquidator)


@internal
def _set_insurance_connector(_insurance_connector: address):
    self.insurance_connector = _insurance_connector
    log InsuranceConnectorUpdated(_insurance_connector)


@external
def set_insurance_connector(_insurance_connector: address):
    """
    @dev Sets the insurance connector contract: a contract for obtaining the total number of
         shares burnt for the purpose of insurance/cover application from the Lido protocol.

    Can only be called by the current admin address.
    """
    self._assert_admin(msg.sender)
    self._set_insurance_connector(_insurance_connector)


@internal
def _set_liquidation_config(
    _liquidations_admin: address,
    _no_liquidation_interval: uint256,
    _restricted_liquidation_interval: uint256
):
    assert _restricted_liquidation_interval >= _no_liquidation_interval

    self.liquidations_admin = _liquidations_admin
    self.no_liquidation_interval = _no_liquidation_interval
    self.restricted_liquidation_interval = _restricted_liquidation_interval

    log LiquidationConfigUpdated(
        _liquidations_admin,
        _no_liquidation_interval,
        _restricted_liquidation_interval
    )


@external
def set_liquidation_config(
    _liquidations_admin: address,
    _no_liquidation_interval: uint256,
    _restricted_liquidation_interval: uint256,
):
    """
    @dev Sets the liquidation config consisting of liquidation admin, the address that is allowed
         to sell stETH rewards to UST during after the no-liquidation interval ends and before
         the restricted liquidation interval ends, as well as both intervals.

    Can only be called by the current admin address.
    """
    self._assert_admin(msg.sender)
    self._set_liquidation_config(
        _liquidations_admin,
        _no_liquidation_interval,
        _restricted_liquidation_interval
    )


@internal
def _set_anchor_rewards_distributor(_anchor_rewards_distributor: bytes32):
    self.anchor_rewards_distributor = _anchor_rewards_distributor
    log AnchorRewardsDistributorUpdated(_anchor_rewards_distributor)


@external
def set_anchor_rewards_distributor(_anchor_rewards_distributor: bytes32):
    """
    @dev Sets the Terra-side UST rewards distributor contract allowing Terra-side bETH holders
         to claim their staking rewards in the UST form.

    Can only be called by the current admin address.
    """
    self._assert_admin(msg.sender)
    self._set_anchor_rewards_distributor(_anchor_rewards_distributor)


@external
def configure(
    _bridge_connector: address,
    _rewards_liquidator: address,
    _insurance_connector: address,
    _liquidations_admin: address,
    _no_liquidation_interval: uint256,
    _restricted_liquidation_interval: uint256,
    _anchor_rewards_distributor: bytes32,
):
    """
    @dev A shortcut function for setting all admin-configurable settings at once.

    Can only be called by the current admin address.
    """
    self._assert_admin(msg.sender)
    self._set_bridge_connector(_bridge_connector)
    self._set_rewards_liquidator(_rewards_liquidator)
    self._set_insurance_connector(_insurance_connector)
    self._set_liquidation_config(
        _liquidations_admin,
        _no_liquidation_interval,
        _restricted_liquidation_interval
    )
    self._set_anchor_rewards_distributor(_anchor_rewards_distributor)


@internal
@view
def _get_rate(_is_withdraw_rate: bool) -> uint256:
    steth_balance: uint256 = ERC20(self.steth_token).balanceOf(self)
    beth_supply: uint256 = ERC20(self.beth_token).totalSupply() - self.total_beth_refunded
    if steth_balance >= beth_supply:
        return 10**18
    elif _is_withdraw_rate:
        return (steth_balance * 10**18) / beth_supply
    elif steth_balance == 0:
        return 10**18
    else:
        return (beth_supply * 10**18) / steth_balance


@external
@view
def get_rate() -> uint256:
    """
    @dev How much bETH one receives for depositing one stETH, and how much bETH one needs
         to provide to withdraw one stETH, 10**18 being the 1:1 rate.

    This rate is notmally 10**18 (1:1) but might be different after severe penalties inflicted
    on the Lido validators.
    """
    return self._get_rate(False)

@view
@external
def can_deposit_or_withdraw() -> bool:
    """
    @dev Whether deposits and withdrawals are enabled.

    Deposits and withdrawals are disabled if stETH token has rebased (e.g. Lido
    oracle reported Beacon chain rewards/penalties or insurance was applied) but
    vault rewards accrued since the last rewards sell operation are not sold to
    UST yet. Normally, this period should not last more than a couple of minutes
    each 24h.
    """
    return self.operations_allowed


@external
@payable
def submit(
    _amount: uint256,
    _terra_address: bytes32,
    _extra_data: Bytes[1024],
    _expected_version: uint256
) -> (uint256, uint256):
    """
    @dev Locks the `_amount` of provided ETH or stETH tokens in return for bETH tokens
         minted to the `_terra_address` address on the Terra blockchain.

    When ETH is provided, it will be deposited to Lido and converted to stETH first.
    In this case, transaction value must be the same as `_amount` argument.

    To provide stETH, set the transavtion value to zero and approve this contract for spending
    the `_amount` of stETH on your behalf.

    The call fails if `AnchorVault.can_deposit_or_withdraw()` is false.

    The conversion rate from stETH to bETH should normally be 1 but might be different after
    severe penalties inflicted on the Lido validators. You can obtain the current conversion
    rate by calling `AnchorVault.get_rate()`.
    """
    raise "Minting is closed. Context: https://research.lido.fi/t/sunsetting-lido-on-terra/2367"

@internal
def _withdraw(recipient: address, beth_amount: uint256, steth_rate: uint256) -> uint256:
    steth_amount: uint256 = (beth_amount * steth_rate) / 10**18
    ERC20(self.steth_token).transfer(recipient, steth_amount)
    return steth_amount



@external
def withdraw(
    _beth_amount: uint256,
    _expected_version: uint256,
    _recipient: address = msg.sender
) -> uint256:
    """
    @dev Burns the `_beth_amount` of provided Ethereum-side bETH tokens in return for stETH
         tokens transferred to the `_recipient` Ethereum address.

    To withdraw Terra-side bETH, you should firstly transfer the tokens to the Ethereum
    blockchain.

    The call fails if `AnchorVault.can_deposit_or_withdraw()` returns false.

    The conversion rate from stETH to bETH should normally be 1 but might be different after
    severe penalties inflicted on the Lido validators. You can obtain the current conversion
    rate by calling `AnchorVault.get_rate()`.
    """
    self._assert_not_stopped()
    self._assert_version(_expected_version)

    steth_rate: uint256 = self._get_rate(True)
    Mintable(self.beth_token).burn(msg.sender, _beth_amount)
    steth_amount: uint256 = self._withdraw(_recipient, _beth_amount, steth_rate)

    log Withdrawn(_recipient, _beth_amount, steth_amount)

    return steth_amount

@external
def burn_refunded_beth(beth_amount: uint256):
    """
    @dev Burns bETH belonging to the AnchorVault contract address, assuming that
         the corresponding stETH amount was already withdrawn from the vault.

    Can only be called by the current admin address.

    Used by the governance to actually burn bETH that previously became locked as
    the result of a contract or user error and was subsequently refunded.

    Reverts unless at least the specified bETH amount was refunded and wasn't
    burned yet.

    """
    self._assert_admin(msg.sender)

    # this will revert if beth_amount exceeds total_beth_refunded
    self.total_beth_refunded -= beth_amount

    Mintable(self.beth_token).burn(self, beth_amount)

    log RefundedBethBurned(beth_amount)

@external
def finalize_upgrade_v4():
    """
    @dev Performs state changes required for proxy upgrade from version 3 to version 4.

    Can only be called by the current admin address.
    """
    self._assert_admin(msg.sender)
    self._assert_version(3)
    self._initialize_v4()

@external
def collect_rewards() -> uint256:
    """
    @dev Sells stETH rewards and transfers them to the distributor contract in the
         Terra blockchain.
    """
    raise "Collect rewards stopped"
