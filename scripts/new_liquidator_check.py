import os
from brownie import interface, accounts, network, Contract, ZERO_ADDRESS
from brownie import (
    bEth,
    AnchorVault,
    AnchorVaultProxy,
    BridgeConnectorShuttle,
    RewardsLiquidator,
    InsuranceConnector
)

import utils.log as log
from utils.mainnet_fork import chain_snapshot


def assert_equals(desc, actual, expected):
    assert actual == expected
    log.ok(desc, actual)


def main():
    vault_proxy = AnchorVaultProxy.at('0xA2F987A546D4CD1c607Ee8141276876C26b72Bdf')
    vault_impl = AnchorVault.at('0x0627054d17eAe63ec23C6d8b07d8Db7A66ffd45a')
    vault = Contract.from_abi('AnchorVault', vault_proxy.address, AnchorVault.abi)
    beth_token = bEth.at('0x707F9118e33A9B8998beA41dd0d46f38bb963FC8')
    beth_shuttle_vault = interface.ShuttleVault('0xF9dcf31EE6EB94AB732A43c2FbA1dC6179c98965')
    ust_token = interface.ERC20('0xa47c8bf37f92aBed4A126BDA807A7b7498661acD')
    steth_token = interface.Lido('0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84')

    bridge_connector = BridgeConnectorShuttle.at('0x513251faB2542532753972B8FE9A7b60621affaD')
    old_rewards_liquidator = RewardsLiquidator.at('0xdb99Fdb42FEc8Ba414ea60b3a189208bBdbfa321')
    insurance_connector = InsuranceConnector.at('0x2BDfD3De0fF23373B621CDAD0aD3dF1580efE701')

    terra_rewards_distributor = '0x2c4ab12675bccba793170e21285f8793611135df000000000000000000000000'

    new_liquidator_address = os.getenv('LIQUIDATOR_ASSRESS', default=None)
    new_liquidator_deployed = new_liquidator_address is not None
    if new_liquidator_deployed:
        new_rewards_liquidator = RewardsLiquidator.at(new_liquidator_address)
    new_liquidator_configured = new_liquidator_deployed and vault.rewards_liquidator() == new_rewards_liquidator.address

    print('loading liquidations admin account...')
    liquidations_admin = accounts.load('anchor-mainnet-liquidator')

    dev_multisig = '0x3cd9F71F80AB08ea5a7Dca348B5e94BC595f26A0'
    lido_deployer_3 = '0xe19fc582dd93FA876CF4061Eb5456F310144F57b'

    log.ok('dev multisig', dev_multisig)

    print()

    log.ok('stETH', steth_token.address)
    log.ok('UST', ust_token.address)

    print()
    beth_supply_before = beth_token.totalSupply()
    log.ok('bETH', beth_token.address)
    assert_equals('  admin', beth_token.admin(), dev_multisig)
    assert_equals('  minter', beth_token.minter(), vault_proxy)
    assert_equals('  totalSupply', beth_token.totalSupply(), beth_supply_before)
    assert_equals('  name', beth_token.name(), 'bETH')
    assert_equals('  symbol', beth_token.symbol(), 'bETH')
    assert_equals('  decimals', beth_token.decimals(), 18)

    print()

    log.ok('ShuttleVault for bETH', beth_shuttle_vault.address)
    assert_equals('  token()', beth_shuttle_vault.token(), beth_token.address)

    print()

    log.ok('AnchorVault impl', vault_impl.address)
    assert_equals('  admin', vault_impl.admin(), ZERO_ADDRESS)
    assert_equals('  bridge_connector', vault_impl.bridge_connector(), ZERO_ADDRESS)
    assert_equals('  rewards_liquidator', vault_impl.rewards_liquidator(), ZERO_ADDRESS)
    assert_equals('  insurance_connector', vault_impl.insurance_connector(), ZERO_ADDRESS)

    print()

    log.ok('AnchorVaultProxy', vault_proxy.address)
    assert_equals('  proxy_getAdmin', vault_proxy.proxy_getAdmin(), dev_multisig)
    assert_equals('  proxy_getIsOssified', vault_proxy.proxy_getIsOssified(), False)
    assert_equals('  implementation', vault_proxy.implementation(), vault_impl)
    assert_equals('  admin', vault.admin(), dev_multisig)
    assert_equals('  beth_token', vault.beth_token(), beth_token.address)
    assert_equals('  steth_token', vault.steth_token(), steth_token.address)
    assert_equals('  bridge_connector', vault.bridge_connector(), bridge_connector.address)
    if new_liquidator_configured:
        log.nb('  rewards_liquidator', 'skipped')
    else:
        assert_equals('  rewards_liquidator', vault.rewards_liquidator(), old_rewards_liquidator.address)
    assert_equals('  insurance_connector', vault.insurance_connector(), insurance_connector.address)

    print()

    log.ok('BridgeConnectorShuttle', bridge_connector.address)
    assert_equals('  beth_token', bridge_connector.beth_token(), beth_token.address)
    assert_equals('  beth_token_vault', bridge_connector.beth_token_vault(), beth_shuttle_vault.address)
    assert_equals('  ust_wrapper_token', bridge_connector.ust_wrapper_token(), ust_token)

    print()

    log.ok('InsuranceConnector', insurance_connector.address)

    print()

    no_liquidation_interval = 0
    restricted_liquidation_interval = 26 * 60 * 60

    log.ok('liquidations admin', liquidations_admin.address)
    log.ok('no liquidation interval', f'{no_liquidation_interval} sec ({no_liquidation_interval / 3600} hrs)')
    log.ok('restricted liquidation interval', f'{restricted_liquidation_interval} sec ({restricted_liquidation_interval / 3600} hrs)')
    log.ok('terra rewards distributor', terra_rewards_distributor)

    print()

    if network.show_active() != 'development':
        print('Running on a live network, cannot run further checks.')
        print('Run on a mainnet fork to do this.')
        return

    with chain_snapshot():
        dev_multisig_acct = accounts.at(dev_multisig, force=True)
        lido_deployer_acct = accounts.at(lido_deployer_3, force=True)
        bridge_balance_before = beth_token.balanceOf(beth_shuttle_vault)

        #liquidator upgrade
        max_steth_eth_price_difference_percent = 1.5
        max_eth_usdc_price_difference_percent = 3
        max_usdc_ust_price_difference_percent = 3
        max_steth_ust_price_difference_percent = 5

        if not new_liquidator_deployed:
            log.nb('Deploying new RewardsLiquidator')
            new_rewards_liquidator = RewardsLiquidator.deploy(
                vault.address,
                dev_multisig,
                int(max_steth_eth_price_difference_percent * 10**18 / 100),
                int(max_eth_usdc_price_difference_percent * 10**18 / 100),
                int(max_usdc_ust_price_difference_percent * 10**18 / 100),
                int(max_steth_ust_price_difference_percent * 10**18 / 100),
                {'from': lido_deployer_acct}
            )

        log.ok('RewardsLiquidator (new)', new_rewards_liquidator.address)
        assert_equals('  admin', new_rewards_liquidator.admin(), dev_multisig)
        assert_equals('  vault', new_rewards_liquidator.vault(), vault_proxy.address)
        assert_equals('  max_steth_eth_price_difference_percent',
            new_rewards_liquidator.max_steth_eth_price_difference_percent(),
            int(max_steth_eth_price_difference_percent * 10**18 / 100)
        )
        assert_equals('  max_eth_usdc_price_difference_percent',
            new_rewards_liquidator.max_eth_usdc_price_difference_percent(),
            int(max_eth_usdc_price_difference_percent * 10**18 / 100)
        )
        assert_equals('  max_usdc_ust_price_difference_percent',
            new_rewards_liquidator.max_usdc_ust_price_difference_percent(),
            int(max_usdc_ust_price_difference_percent * 10**18 / 100)
        )
        assert_equals('  max_steth_ust_price_difference_percent',
            new_rewards_liquidator.max_steth_ust_price_difference_percent(),
            int(max_steth_ust_price_difference_percent * 10**18 / 100)
        )


        if not new_liquidator_configured:
            log.nb('Updating address at Vault')
            tx_data = vault.set_rewards_liquidator.encode_input(new_rewards_liquidator)
            log.ok('multisig tx recipient', vault_proxy.address)
            log.ok('multisig tx data', tx_data)
            print()

            tx = dev_multisig_acct.transfer(to=vault.address, data=tx_data)
            tx.info()

        log.ok('AnchorVault')
        assert_equals('  admin', vault.admin(), dev_multisig)
        assert_equals('  beth_token', vault.beth_token(), beth_token.address)
        assert_equals('  steth_token', vault.steth_token(), steth_token.address)
        assert_equals('  bridge_connector', vault.bridge_connector(), bridge_connector.address)
        assert_equals('  rewards_liquidator', vault.rewards_liquidator(), new_rewards_liquidator.address)
        assert_equals('  insurance_connector', vault.insurance_connector(), insurance_connector.address)
        assert_equals('  liquidations_admin', vault.liquidations_admin(), liquidations_admin.address)
        assert_equals('  no_liquidation_interval', vault.no_liquidation_interval(), no_liquidation_interval)
        assert_equals('  restricted_liquidation_interval', vault.restricted_liquidation_interval(), restricted_liquidation_interval)
        assert_equals('  anchor_rewards_distributor', vault.anchor_rewards_distributor(), terra_rewards_distributor)
        assert_equals('  get_rate', vault.get_rate(), 10**18)

        print()
        log.nb('Selling rewards...')

        tx = vault.collect_rewards({'from': liquidations_admin})
        tx.info()

        assert_equals('  can_deposit_or_withdraw', vault.can_deposit_or_withdraw(), True)

        print()
        log.nb('Submitting stETH...')

        assert beth_token.totalSupply() == beth_supply_before

        holder_1 = accounts[0]

        steth_token.submit(ZERO_ADDRESS, {'from': holder_1, 'value': 3 * 10**18})
        assert steth_token.balanceOf(holder_1) > 0
        steth_token.approve(vault, 2 * 10**18, {'from': holder_1})

        terra_recipient = '0xabcdef1234abcdef1234abcdef1234abcdef1234000000000000000000000000'
        tx = vault.submit(2 * 10**18, terra_recipient, b'', {'from': holder_1})
        tx.info()

        bridge_balance = beth_token.balanceOf(beth_shuttle_vault)

        assert beth_token.balanceOf(holder_1) == 0
        assert bridge_balance > bridge_balance_before + (1.999 * 10**18)
        assert bridge_balance <= bridge_balance_before + (2 * 10**18)
        assert beth_token.totalSupply() == beth_supply_before + bridge_balance - bridge_balance_before

        log.ok('bridge bETH balance', bridge_balance / 10**18)

        print()
        log.nb('Submitting ETH...')

        holder_2 = accounts[1]

        tx = vault.submit(2 * 10**18, terra_recipient, b'', {'from': holder_1, 'value': 2 * 10**18})
        tx.info()

        bridge_balance = beth_token.balanceOf(beth_shuttle_vault)

        assert beth_token.balanceOf(holder_2) == 0
        assert bridge_balance > bridge_balance_before + (2 * 1.999 * 10**18)
        assert bridge_balance <= bridge_balance_before + (4 * 10**18)
        assert beth_token.totalSupply() == beth_supply_before + bridge_balance - bridge_balance_before

        log.ok('bridge bETH balance', bridge_balance / 10**18)