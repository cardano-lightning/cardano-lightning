use aiken/collection/dict.{Dict}
use aiken/primitive/bytearray
use cardano/assets.{AssetName}
use cl/types.{ChannelId}

/// A bolt token is a placeholder.
/// In the case a tx has no mint or burn of thread tokens
/// a single 'bolt' token is used.
pub const bolt = "⚡"

const prefix = "⚡"

const prefix_len = prefix |> bytearray.length

pub fn get_cid(name: AssetName) -> ChannelId {
  name |> bytearray.drop(prefix_len)
}

//
// Return value is `(n_mint, n_burn)`
/// We depend on the following assumptions: 
/// 
/// - If a bolt token exists, it will appear first 
/// - All other tokens must be NFTs
pub fn count_tokens(tokens: Dict<AssetName, Int>) -> (Int, Int) {
  do_count_tokens(tokens |> dict.to_pairs, 0, 0)
}

fn do_count_tokens(
  tokens: Pairs<AssetName, Int>,
  n_mint: Int,
  n_burn: Int,
) -> (Int, Int) {
  when tokens is {
    [Pair(curr, amt), ..rest] ->
      if curr == bolt {
        expect rest == []
        (0, 0)
      } else if amt == 1 {
        do_count_tokens(rest, n_mint + 1, n_burn)
      } else if amt == -1 {
        do_count_tokens(rest, n_mint, n_burn + 1)
      } else {
        fail @"illegal value"
      }
    [] -> (n_mint, n_burn)
  }
}
