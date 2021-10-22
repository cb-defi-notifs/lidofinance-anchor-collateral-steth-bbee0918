# @version 0.2.12
# @author skozin <info@lido.fi>
# @licence MIT
from vyper.interfaces import ERC20

WORMHOLE_TOKEN_BRIDGE: constant(address) = 0x6c4c12987303b2c94b2C76c612Fc5F4D2F0360F7
BETH_TOKEN: constant(address) = 0x707F9118e33A9B8998beA41dd0d46f38bb963FC8
UST_WRAPPER_TOKEN: constant(address) = ZERO_ADDRESS # TODO: set real address
TERRA_CHAIN_ID: constant(uint256) = 3               # TODO: verify


next_nonce: uint256


@internal
def _transferAsset(bridge: address, asset: address, amount: uint256, recipient: bytes32):
    nonce: uint256 = self.next_nonce
    arbiter_fee: uint256 = 0 # TODO: figure out how to calculate and handle

    self.next_nonce = nonce + 1

    ERC20(asset).approve(bridge, amount)

    # Method signature: https://etherscan.io/address/0x6c4c12987303b2c94b2c76c612fc5f4d2f0360f7#code#F2#L93
    # Vyper does not support uint16 and uint32. Using raw_call() for compatibility.
    # TODO: need to check that low-level call succeeds.
    raw_call(
        bridge,
        concat(
            method_id('transferTokens(address,uint256,uint16,bytes32,uint256,uint32)'),
            convert(asset, bytes32),
            convert(amount, bytes32),
            convert(TERRA_CHAIN_ID, bytes32),
            recipient,
            convert(arbiter_fee, bytes32),
            convert(nonce, bytes32)
        )
    )


@external
def forward_beth(_terra_address: bytes32, _amount: uint256, _extra_data: Bytes[1024]):
    self._transferAsset(WORMHOLE_TOKEN_BRIDGE, BETH_TOKEN, _amount, _terra_address)


@external
def forward_ust(_terra_address: bytes32, _amount: uint256, _extra_data: Bytes[1024]):
    self._transferAsset(WORMHOLE_TOKEN_BRIDGE, UST_WRAPPER_TOKEN, _amount, _terra_address)


@external
@view
def adjust_amount(_amount: uint256, _decimals: uint256) -> uint256:
    # Wormhole only supports the precision of 9 decimals
    # TODO: verify that this is true for Wormhole v2
    mult: uint256 = 10 ** (_decimals - 9)
    return (_amount / mult) * mult
