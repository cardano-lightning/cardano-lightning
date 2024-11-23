use aiken/primitive/bytearray
use cardano/assets.{AssetName}
use cl/types.{ChannelId}

pub const bolt = "⚡"

const prefix = "⚡"

const prefix_len = prefix |> bytearray.length

pub fn get_cid(name: AssetName) -> ChannelId {
  name |> bytearray.drop(prefix_len)
}
