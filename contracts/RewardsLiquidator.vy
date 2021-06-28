# @version 0.2.12
# @author skozin <info@lido.fi>
# @licence MIT
from vyper.interfaces import ERC20


interface ERC20Decimals:
    def decimals() -> uint256: view


interface LidoStEthPriceFeed:
    def current_price() -> (uint256, bool): view


interface ChainlinkAggregatorV3Interface:
    def decimals() -> uint256: view
    # (roundId: uint80, answer: int256, startedAt: uint256, updatedAt: uint256, answeredInRound: uint80)
    def latestRoundData() -> (uint256, int256, uint256, uint256, uint256): view


interface CurveStableSwap:
    def get_dy(i: int128, j: int128, dx: uint256) -> uint256: view
    def exchange(i: int128, j: int128, dx: uint256, min_dy: uint256) -> uint256: payable


UST_TOKEN: constant(address) = 0xa47c8bf37f92aBed4A126BDA807A7b7498661acD
STETH_TOKEN: constant(address) = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84
WETH_TOKEN: constant(address) = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2

LIDO_STETH_ETH_FEED: constant(address) = 0xAb55Bf4DfBf469ebfe082b7872557D1F87692Fe6
CHAINLINK_ETH_USD_FEED: constant(address) = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419

CURVE_STETH_POOL: constant(address) = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022
SUSHISWAP_ROUTER_V2: constant(address) = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F

CURVE_ETH_INDEX: constant(uint256) = 0
CURVE_STETH_INDEX: constant(uint256) = 1

SUSHISWAP_EXCH_PATH: constant(address[2]) = [WETH_TOKEN, UST_TOKEN]


# An address that is allowed to configure the liquidator settings.
admin: public(address)

# Maximum difference (in percents multiplied by 10**18) between the resulting
# ETH/UST price and the ETH/USD anchor price obtained from the oracle.
max_eth_price_difference_percent: public(uint256)

# Maximum difference (in percents multiplied by 10**18) between the resulting
# stETH/ETH price and the current stETH/ETH price obtained from the stETH price
# feed (given that the current price is already considered safe by the feed).
max_steth_price_difference_percent: public(uint256)


@external
def __init__(
    admin: address,
    max_steth_price_difference_percent: uint256,
    max_eth_price_difference_percent: uint256
):
    assert max_steth_price_difference_percent <= 10**18, "invalid percentage"
    assert max_eth_price_difference_percent <= 10**18, "invalid percentage"

    self.admin = admin
    self.max_steth_price_difference_percent = max_steth_price_difference_percent
    self.max_eth_price_difference_percent = max_eth_price_difference_percent


@external
@payable
def __default__():
    pass


@external
def change_admin(new_admin: address):
    assert msg.sender == self.admin
    self.admin = new_admin


@external
def configure(
    max_steth_price_difference_percent: uint256,
    max_eth_price_difference_percent: uint256
):
    assert msg.sender == self.admin
    assert max_steth_price_difference_percent <= 10**18, "invalid percentage"
    assert max_eth_price_difference_percent <= 10**18, "invalid percentage"

    self.max_steth_price_difference_percent = max_steth_price_difference_percent
    self.max_eth_price_difference_percent = max_eth_price_difference_percent


@pure
@internal
def _percentage_diff(new: uint256, old: uint256) -> uint256:
    if new > old :
        return (new - old) * (10 ** 18) / old
    else:
        return (old - new) * (10 ** 18) / old


@internal
def _get_steth_safe_price() -> uint256:
    steth_price: uint256 = 0
    is_price_safe: bool = False
    (steth_price, is_price_safe) = LidoStEthPriceFeed(LIDO_STETH_ETH_FEED).current_price()
    assert is_price_safe or steth_price > 10**18, "stETH price unsafe"
    return steth_price


@internal
def _get_eth_anchor_price() -> uint256:
    eth_price_decimals: uint256 = ChainlinkAggregatorV3Interface(CHAINLINK_ETH_USD_FEED).decimals()
    assert 0 < eth_price_decimals and eth_price_decimals <= 18

    round_id: uint256 = 0
    answer: int256 = 0
    started_at: uint256 = 0
    updated_at: uint256 = 0
    answered_in_round: uint256 = 0

    (round_id, answer, started_at, updated_at, answered_in_round) = \
        ChainlinkAggregatorV3Interface(CHAINLINK_ETH_USD_FEED).latestRoundData()

    assert updated_at != 0

    return convert(answer, uint256) * (10 ** (18 - eth_price_decimals))


@internal
@pure
def _abi_extract_sushi_result(result: Bytes[128]) -> uint256:
    # The return type is uint256[] and the actual length of the array is 2, so the
    # layout of the data is (pad32(64) . pad32(2) . pad32(arr[0]) . pad32(arr[1])).
    # We need the second array item, thus the byte offset is 96.
    return convert(extract32(result, 96), uint256)


@internal
@view
def _sushi_get_ust_amount_out(eth_amount_in: uint256) -> uint256:
    result: Bytes[128] = raw_call(
        SUSHISWAP_ROUTER_V2,
        concat(
            # uint256 amountIn, address[] calldata path
            method_id("getAmountsOut(uint256,address[])"),
            convert(eth_amount_in, bytes32),
            convert(64, bytes32),
            convert(2, bytes32),
            convert(WETH_TOKEN, bytes32),
            convert(UST_TOKEN, bytes32)
        ),
        max_outsize=128,
        is_static_call=True
    )
    return self._abi_extract_sushi_result(result)


@internal
def _sushi_sell_eth_to_ust(
    eth_amount_in: uint256,
    ust_amount_out_min: uint256,
    ust_recipient: address
) -> uint256:
    result: Bytes[128] = raw_call(
        SUSHISWAP_ROUTER_V2,
        concat(
            # uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
            method_id("swapExactETHForTokens(uint256,address[],address,uint256)"),
            convert(ust_amount_out_min, bytes32),
            convert(128, bytes32),
            convert(ust_recipient, bytes32),
            convert(MAX_UINT256, bytes32),
            convert(2, bytes32),
            convert(WETH_TOKEN, bytes32),
            convert(UST_TOKEN, bytes32)
        ),
        value=eth_amount_in,
        max_outsize=128
    )
    return self._abi_extract_sushi_result(result)


@external
def liquidate(ust_recipient: address) -> uint256:
    steth_amount: uint256 = ERC20(STETH_TOKEN).balanceOf(self)
    assert steth_amount > 0, "zero stETH balance"

    assert ERC20Decimals(UST_TOKEN).decimals() == 18
    assert ERC20Decimals(STETH_TOKEN).decimals() == 18

    steth_price: uint256 = self._get_steth_safe_price()

    min_eth_amount: uint256 = (
        ((steth_price * steth_amount) / 10**18) *
        (10**18 - self.max_steth_price_difference_percent)
    ) / 10**18

    ERC20(STETH_TOKEN).approve(CURVE_STETH_POOL, steth_amount)

    eth_amount: uint256 = CurveStableSwap(CURVE_STETH_POOL).exchange(
        CURVE_STETH_INDEX,
        CURVE_ETH_INDEX,
        steth_amount,
        min_eth_amount
    )

    assert eth_amount >= min_eth_amount, "insuff. ETH return"
    assert self.balance >= eth_amount

    eth_anchor_price: uint256 = self._get_eth_anchor_price()
    ust_amount: uint256 = self._sushi_get_ust_amount_out(eth_amount)
    eth_price: uint256 = (ust_amount * 10**18) / eth_amount

    assert self._percentage_diff(eth_anchor_price, eth_price) <= \
        self.max_eth_price_difference_percent, \
        "ETH price unsafe"

    ust_amount_actual: uint256 = self._sushi_sell_eth_to_ust(eth_amount, ust_amount, ust_recipient)

    assert ust_amount_actual >= ust_amount, "insuff. UST return"
    return ust_amount_actual
