import math
import brownie
import pytest
from brownie.network import web3
from utils.beth import beth_holders, CSV_DOWNLOADED_AT_BLOCK
import utils.config as config

STETH_ERROR_MARGIN = 2

@pytest.fixture(scope="module")
def steth_approx_equal():
    def equal(steth_amount_a, steth_amount_b):
        return math.isclose(
            a=steth_amount_a, b=steth_amount_b, abs_tol=STETH_ERROR_MARGIN
        )

    return equal

@pytest.mark.parametrize("rebase_coeff", [0, 1.01, 0.9])
def test_withdraw_using_actual_holders(
    lido_oracle_report, rebase_coeff,
    accounts, steth_token, deploy_vault_and_pass_dao_vote, steth_approx_equal
):
    """
    @dev Number of tokens that were burned after the incident the 2022-01-26 incident 
         caused by incorrect address encoding produced by cached UI code after onchain 
         migration to the Wormhole bridge.
    Tx 1: 0xc875f85f525d9bc47314eeb8dc13c288f0814cf06865fc70531241e21f5da09d
    bETH burned: 4449999990000000000
    Tx 2: 0x7abe086dd5619a577f50f87660a03ea0a1934c4022cd432ddf00734771019951
    bETH burned: 439111118580000000000
    """

    #check block number for downloaded file
    assert steth_approx_equal(web3.eth.block_number, CSV_DOWNLOADED_AT_BLOCK)


    BETH_BURNED = 4449999990000000000 + 439111118580000000000

    vault = brownie.Contract.from_abi(
        "AnchorVault", config.vault_proxy_addr, brownie.AnchorVault.abi
    )

    beth_token = brownie.interface.ERC20(vault.beth_token())

    deploy_vault_and_pass_dao_vote()
    
    if rebase_coeff != 0:
        lido_oracle_report(steth_rebase_mult=rebase_coeff)

    #vault balance
    steth_vault_balance = steth_token.balanceOf(vault.address)
    beth_total_supply = beth_token.totalSupply()
    total_beth_refunded = vault.total_beth_refunded()
    beth_balance = beth_total_supply - total_beth_refunded
    
    #calculate withdrawal rate
    rate = 1
    if steth_vault_balance < beth_balance:
        rate = steth_vault_balance / beth_balance

    print('')
    print('steth_vault_balance', steth_vault_balance)
    print('beth_total_supply', beth_total_supply)
    print('total_beth_refunded', total_beth_refunded)
    print('beth_balance', beth_balance)
    print('rate', rate)
    print('')


    prev_beth_total_supply = beth_token.totalSupply()

    withdrawn = 0

    count = len(beth_holders)
    print("Total holders", len(beth_holders))

    ##current version
    vault_version = vault.version()

    i = 0
    for holder in beth_holders:
        i += 1
        
        config.progress(i, count)

        [holder_address, _, _] = holder

        holder_account = accounts.at(holder_address, True)

        # not using balances from csv, since they may change
        prev_beth_balance = beth_token.balanceOf(holder_account)
        prev_steth_balance = steth_token.balanceOf(holder_account)

        is_wormhole = holder_account.address == config.wormhole_token_bridge_addr

        withdraw_amount = prev_beth_balance

        if is_wormhole:
            withdraw_amount = prev_beth_balance - BETH_BURNED

        vault.withdraw(
            withdraw_amount, vault_version, holder_account, {"from": holder_account}
        )

        withdrawn += withdraw_amount

        assert beth_token.balanceOf(holder_account) == prev_beth_balance - withdraw_amount
        assert steth_approx_equal(
            steth_token.balanceOf(holder_account),
            prev_steth_balance + withdraw_amount * rate,
        )

    assert beth_token.totalSupply() == prev_beth_total_supply - withdrawn
    assert beth_token.totalSupply() == BETH_BURNED