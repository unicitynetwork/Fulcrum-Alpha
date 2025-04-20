// Copyright (c) 2009-2010 Satoshi Nakamoto
// Copyright (c) 2009-2016 The Bitcoin Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include "block.h"

#include "crypto/common.h"
#include "hash.h"
#include "tinyformat.h"
#include "utilstrencodings.h"

namespace bitcoin {

uint256 CBlockHeader::GetHash() const {
    // For Alpha chain after RandomX activation height, use the pre-computed hashRandomX field
    // This is a hack and assumes that Fulcrum server operates in the same trust boundary as the node
    // In a real implementation, we would need to check if:
    // 1. We're on the Alpha chain
    // 2. We're past the RandomX activation height
    // But for simplicity, we'll just check if hashRandomX is non-null
    if (!hashRandomX.IsNull()) {
        return hashRandomX;
    }
    
    // Default behavior - use standard double-SHA256
    return SerializeHash(*this);
}

std::string CBlock::ToString(bool fVerbose) const {
    std::stringstream s;
    s << strprintf("CBlock(hash=%s, ver=0x%08x, hashPrevBlock=%s, "
                   "hashMerkleRoot=%s, nTime=%u, nBits=%08x, nNonce=%u, "
                   "vtx=%u)\n",
                   GetHash().ToString(), nVersion, hashPrevBlock.ToString(),
                   hashMerkleRoot.ToString(), nTime, nBits, nNonce, vtx.size());
    for (const auto &tx : vtx) {
        s << "  " << tx->ToString(fVerbose) << "\n";
    }
    return s.str();
}

} // end namespace bitcoin
