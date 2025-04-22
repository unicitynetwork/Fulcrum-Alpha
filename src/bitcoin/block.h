// Copyright (c) 2009-2010 Satoshi Nakamoto
// Copyright (c) 2009-2016 The Bitcoin Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#pragma once

#include "transaction.h"
#include "serialize.h"
#include "uint256.h"

#include <utility>

namespace bitcoin {
/**
 * Nodes collect new transactions into a block, hash them into a hash tree, and
 * scan through nonce values to make the block's hash satisfy proof-of-work
 * requirements. When they solve the proof-of-work, they broadcast the block to
 * everyone and the block is added to the block chain. The first transaction in
 * the block is a special one that creates a new coin owned by the creator of
 * the block.
 */
class CBlockHeader {
public:
    // header
    int32_t nVersion;
    uint256 hashPrevBlock;
    uint256 hashMerkleRoot;
    uint32_t nTime;
    uint32_t nBits;
    uint32_t nNonce;
    // Alpha extension
    uint256 hashRandomX;

    CBlockHeader() noexcept { SetNull(); }

    SERIALIZE_METHODS(CBlockHeader, obj) {
        READWRITE(obj.nVersion);
        READWRITE(obj.hashPrevBlock);
        READWRITE(obj.hashMerkleRoot);
        READWRITE(obj.nTime);
        READWRITE(obj.nBits);
        READWRITE(obj.nNonce);
        
        // Alpha extension - include hashRandomX field for RandomX blocks
        // RandomX blocks are identified by the version bit 0x20000000
        // This bit is set on all blocks from height ALPHA_RANDOMX_ACTIVATION_HEIGHT onwards
        const bool isRandomXBlock = (obj.nVersion & 0x20000000) == 0x20000000;
        if (isRandomXBlock) {
            READWRITE(obj.hashRandomX);
        }
    }

    void SetNull() noexcept {
        nVersion = 0;
        hashPrevBlock.SetNull();
        hashMerkleRoot.SetNull();
        nTime = 0u;
        nBits = 0u;
        nNonce = 0u;
        hashRandomX.SetNull();
    }

    bool IsNull() const noexcept { return nBits == 0; }

    uint256 GetHash() const;

    int64_t GetBlockTime() const noexcept { return int64_t(nTime); }
};

class CBlock : public CBlockHeader {
public:
    // network and disk
    std::vector<CTransactionRef> vtx;

    /// Litecoin only
    litecoin_bits::MimbleBlobPtr mw_blob;

    // memory only
    mutable bool fChecked;

    CBlock() noexcept { SetNull(); }

    CBlock(const CBlockHeader &header) {
        SetNull();
        *(static_cast<CBlockHeader *>(this)) = header;
    }

    SERIALIZE_METHODS(CBlock, obj) {
        READWRITEAS(CBlockHeader, obj);
        READWRITE(obj.vtx);
        // Litecoin only -- Deserialize the mimble-wimble blob at the end under certain conditions (post-activation).
        if constexpr (ser_action.ForRead()) obj.mw_blob.reset();
        if (s.GetVersion() & SERIALIZE_TRANSACTION_USE_MWEB && obj.vtx.size() >= 2 && obj.vtx.back()->IsHogEx()) {
            if constexpr (ser_action.ForRead()) {
                obj.mw_blob = litecoin_bits::EatBlockMimbleBlob(s);
            } else {
                if (obj.mw_blob) {
                    s.write(reinterpret_cast<const char *>(std::as_const(*obj.mw_blob).data()), obj.mw_blob->size());
                }
            }
        }
    }

    void SetNull() {
        CBlockHeader::SetNull();
        vtx.clear();
        mw_blob.reset();
        fChecked = false;
    }

    CBlockHeader GetBlockHeader() const { return *this; }

    std::string ToString(bool fVerbose = false) const;
};

/**
 * Describes a place in the block chain to another node such that if the other
 * node doesn't have the same branch, it can find a recent common trunk.  The
 * further back it is, the further before the fork it may be.
 */
struct CBlockLocator {
    std::vector<uint256> vHave;

    constexpr CBlockLocator() noexcept {}

    explicit CBlockLocator(const std::vector<uint256> &vHaveIn)
        : vHave(vHaveIn) {}

    SERIALIZE_METHODS(CBlockLocator, obj) {
        int nVersion = s.GetVersion();
        if (!(s.GetType() & SER_GETHASH)) READWRITE(nVersion);
        READWRITE(obj.vHave);
    }

    void SetNull() { vHave.clear(); }

    bool IsNull() const { return vHave.empty(); }
};

} // end namespace bitcoin
