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
    // For Alpha chain, determine how to get the hash:
    // 1. For blocks after RandomX activation height, the hashRandomX field should contain the hash
    // 2. For earlier blocks, we need to calculate the standard double-SHA256 hash
    
    // If hashRandomX is set (only for blocks after BTC::ALPHA_RANDOMX_ACTIVATION_HEIGHT),
    // use that value directly
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
