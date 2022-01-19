# @version 0.2.16
# @author skozin <info@lido.fi>
# @licence MIT

interface AnchorVault:
    def admin() -> address: view
    def bridge_connector() -> address: view
    def change_admin(new_admin: address): nonpayable
    def set_bridge_connector(bridge_connector: address): nonpayable
    def set_rewards_liquidator(rewards_liquidator: address): nonpayable
    def set_anchor_rewards_distributor(anchor_rewards_distributor: bytes32): nonpayable


event MigrationStarted: pass
event MigrationFinished: pass
event MigrationCancelled: pass


ANCHOR_VAULT: constant(address) = 0xA2F987A546D4CD1c607Ee8141276876C26b72Bdf
LIDO_DAO_AGENT: constant(address) = 0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c

NEW_REWARDS_LIQUIDATOR: constant(address) = 0x8bAdf00d8bADF00D8Badf00D8BADf00D8Badf00d # FIXME
NEW_BRIDGE_CONNECTOR: constant(address) = 0x8bAdf00d8bADF00D8Badf00D8BADf00D8Badf00d # FIXME
NEW_ANCHOR_REWARDS_DISTRIBUTOR: constant(bytes32) = 0x0000000000000000000000002c4ab12675bccba793170e21285f8793611135df

STATE_MIGRATION_NOT_STARTED: constant(uint256) = 0
STATE_MIGRATION_STARTED: constant(uint256) = 1
STATE_MIGRATION_FINISHED: constant(uint256) = 2
STATE_MIGRATION_CANCELLED: constant(uint256) = 3


state: public(uint256)
executor: public(address)

pre_migration_admin: public(address)
pre_migration_bridge_connector: public(address)


@external
def __init__():
    self.executor = msg.sender
    self.pre_migration_admin = AnchorVault(ANCHOR_VAULT).admin()


@internal
@view
def _assert_authorized(msg_sender: address):
    assert msg_sender == LIDO_DAO_AGENT or msg_sender == self.executor, "unauthorized"


@external
def start_migration():
    self._assert_authorized(msg.sender)

    assert self.state == STATE_MIGRATION_NOT_STARTED, "invalid state"
    self.state = STATE_MIGRATION_STARTED

    # set the connector to zero to prevent users from entering the bridge while migration is ongoing
    self.pre_migration_bridge_connector = AnchorVault(ANCHOR_VAULT).bridge_connector()
    AnchorVault(ANCHOR_VAULT).set_bridge_connector(ZERO_ADDRESS)

    log MigrationStarted()


@external
def finish_migration():
    self._assert_authorized(msg.sender)

    assert self.state == STATE_MIGRATION_STARTED, "invalid state"
    self.state = STATE_MIGRATION_FINISHED

    AnchorVault(ANCHOR_VAULT).set_bridge_connector(NEW_BRIDGE_CONNECTOR)
    AnchorVault(ANCHOR_VAULT).set_rewards_liquidator(NEW_REWARDS_LIQUIDATOR)
    AnchorVault(ANCHOR_VAULT).set_anchor_rewards_distributor(NEW_ANCHOR_REWARDS_DISTRIBUTOR)

    AnchorVault(ANCHOR_VAULT).change_admin(LIDO_DAO_AGENT)

    log MigrationFinished()


@external
def cancel_migration():
    self._assert_authorized(msg.sender)

    prev_state: uint256 = self.state
    assert prev_state <= STATE_MIGRATION_STARTED, "invalid state"
    self.state = STATE_MIGRATION_FINISHED

    if prev_state == STATE_MIGRATION_STARTED:
        AnchorVault(ANCHOR_VAULT).set_bridge_connector(self.pre_migration_bridge_connector)

    AnchorVault(ANCHOR_VAULT).change_admin(self.pre_migration_admin)

    log MigrationCancelled()
