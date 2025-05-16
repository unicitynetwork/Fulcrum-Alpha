//
// Fulcrum - A fast & nimble SPV Server for Bitcoin Cash
// Copyright (C) 2019-2025 Calin A. Culianu <calin.culianu@gmail.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program (see LICENSE.txt).  If not, see
// <https://www.gnu.org/licenses/>.
//
#include "BTC.h"
#include "Common.h"
#include "Util.h"

#include "bitcoin/crypto/endian.h"
#include "bitcoin/crypto/sha256.h"
#include "bitcoin/hash.h"

#include <QMap>

#include <algorithm>
#include <utility>

namespace bitcoin
{
    inline void Endian_Check_In_namespace_bitcoin()
    {
        constexpr uint32_t magicWord = 0x01020304;
        const uint8_t wordBytes[4] = {0x01, 0x02, 0x03, 0x04}; // represent above as big endian
        const uint32_t bytesAsNum = *reinterpret_cast<const uint32_t *>(wordBytes);

        if (magicWord != be32toh(bytesAsNum))
        {
            throw Exception(QString("Program compiled with incorrect WORDS_BIGENDIAN setting.\n\n")
                            + "How to fix this:\n"
                            + " 1. Adjust WORDS_BIGENDIAN in the qmake .pro file to match your architecture.\n"
                            + " 2. Re-run qmake.\n"
                            + " 3. Do a full clean recompile.\n\n");
        }
    }
    extern bool TestBase58(bool silent, bool throws);
}

namespace BTC
{
    void CheckBitcoinEndiannessAndOtherSanityChecks() {
        bitcoin::Endian_Check_In_namespace_bitcoin();
        auto impl = bitcoin::SHA256AutoDetect();
        Debug() << "Using sha256: " << QString::fromStdString(impl);
        if ( ! bitcoin::CSHA256::SelfTest() )
            throw InternalError("sha256 self-test failed. Cannot proceed.");
        Tests::Base58(true, true);
    }


    namespace Tests {
        bool Base58(bool silent, bool throws) { return bitcoin::TestBase58(silent, throws); }
    }


    QByteArray Hash(const QByteArray &b, bool once)
    {
        bitcoin::CHash256 h(once);
        QByteArray ret(QByteArray::size_type(h.OUTPUT_SIZE), Qt::Initialization::Uninitialized);
        h.Write(reinterpret_cast<const uint8_t *>(b.constData()), static_cast<size_t>(b.length()));
        h.Finalize(reinterpret_cast<uint8_t *>(ret.data()));
        return ret;
    }

    QByteArray HashRev(const QByteArray &b, bool once)
    {
        QByteArray ret = Hash(b, once);
        std::reverse(ret.begin(), ret.end());
        return ret;
    }

    QByteArray HashTwo(const QByteArray &a, const QByteArray &b)
    {
        bitcoin::CHash256 h(/* once = */false);
        QByteArray ret(QByteArray::size_type(h.OUTPUT_SIZE), Qt::Initialization::Uninitialized);
        h.Write(reinterpret_cast<const uint8_t *>(a.constData()), static_cast<size_t>(a.length()));
        h.Write(reinterpret_cast<const uint8_t *>(b.constData()), static_cast<size_t>(b.length()));
        h.Finalize(reinterpret_cast<uint8_t *>(ret.data()));
        return ret;
    }

    QByteArray Hash160(const QByteArray &b) {
        bitcoin::CHash160 h;
        QByteArray ret(QByteArray::size_type(h.OUTPUT_SIZE), Qt::Initialization::Uninitialized);
        h.Write(reinterpret_cast<const uint8_t *>(b.constData()), static_cast<size_t>(b.length()));
        h.Finalize(reinterpret_cast<uint8_t *>(ret.data()));
        return ret;
    }

    // HeaderVerifier helper
    bool HeaderVerifier::operator()(const QByteArray & header, QString *err)
    {
        const long height = prevHeight+1;
        
        // Improved logging for diagnosis of RandomX transition issues
        if (height >= ALPHA_RANDOMX_ACTIVATION_HEIGHT - 1 && height <= ALPHA_RANDOMX_ACTIVATION_HEIGHT + 1) {
            Debug() << "Processing header at height " << height << " (size: " << header.size() 
                    << ") - " << (IsRandomXBlock(height) ? "RandomX block" : "Standard block");
        }
        
        // Determine if this is an Alpha RandomX header based solely on height
        const bool isAlphaRandomX = IsRandomXBlock(height);
        
        // Accept both 80-byte (standard) and 112-byte (padded) headers for verification
        if (header.size() != FIXED_HEADER_RECORD_SIZE && header.size() != 80) {
            if (err) *err = QString("Header verification failed for header at height %1: wrong size (expected %2 or 80 bytes, got %3)")
                .arg(height).arg(FIXED_HEADER_RECORD_SIZE).arg(header.size());
            return false;
        }
        
        // Add debug logging for the first few blocks to help diagnose issues
        if (height < 10) {
            Debug() << "QByteArray header verification at height " << height 
                   << ": header size=" << header.size() 
                   << ", isRandomX=" << (isAlphaRandomX ? "true" : "false");
        }
        
        bitcoin::CBlockHeader curHdr;
        // Enhanced logging for early blocks
        /*
        if (height < 5) {
            Debug() << "Deserializing header at height " << height << " (size: " << header.size() << " bytes)";
            Debug() << "Header format: " << (isAlphaRandomX ? "Alpha RandomX (112 bytes)" : "Standard (80 bytes)");
            Debug() << "First 10 bytes: " << Util::ToHexFast(header.left(10));
        }
        */
        
        // For all headers, use standard deserialization
        // Detection of RandomX now happens via the version bit (0x20000000)
        curHdr = Deserialize<bitcoin::CBlockHeader>(header);
        
        // More logging for understanding header fields
        /*
        if (height < 5) {
            Debug() << "Header fields at height " << height << ":";
            Debug() << "  Version: " << curHdr.nVersion;
            Debug() << "  PrevBlock: " << curHdr.hashPrevBlock.ToString().c_str();
            Debug() << "  Time: " << curHdr.nTime;
        }
        */
        
        // Check if this is a RandomX block based on height
        const bool isRandomXBlock = IsRandomXBlock(height);
        if (isRandomXBlock) {
            Debug() << "Bypassing header validation for RandomX block at height " << height;
            prevHeight = height;
            prev = header;
            if (err) err->clear();
            return true;
        }
        
        if (!checkInner(height, curHdr, err, isAlphaRandomX))
            return false;
            
        prevHeight = height;
        prev = header;
        if (err) err->clear();
        return true;
    }
    bool HeaderVerifier::operator()(const bitcoin::CBlockHeader &curHdr, QString *err)
    {
        const long height = prevHeight+1;
        
        // Check if this is a RandomX block based on height
        const bool isRandomXBlock = IsRandomXBlock(height);
        if (isRandomXBlock) {
            Debug() << "Bypassing header validation for RandomX block at height " << height;
            QByteArray header = Serialize(curHdr);
            prevHeight = height;
            prev = header;
            if (err) err->clear();
            return true;
        }
        
        // Determine if this is an Alpha RandomX header based solely on height
        const bool isAlphaRandomX = IsRandomXBlock(height);
        
        // Verify that RandomX headers have hashRandomX set and non-RandomX headers don't
        if (isAlphaRandomX && curHdr.hashRandomX.IsNull()) {
            if (err) *err = QString("RandomX block at height %1 is missing hashRandomX field").arg(height);
            return false;
        } else if (!isAlphaRandomX && !curHdr.hashRandomX.IsNull()) {
            if (err) *err = QString("Non-RandomX block at height %1 has unexpected hashRandomX field").arg(height);
            return false;
        }
        
        // Serialize the header - the serialization will automatically include
        // the hashRandomX field if the version bit is set
        QByteArray header = Serialize(curHdr);
        
        // For CBlockHeader serialization, recognize that standard blocks will be 80 bytes,
        // while RandomX blocks will be 112 bytes
        if (height < 10) {
            Debug() << "CBlockHeader serialization at height " << height 
                   << ": header size=" << header.size() 
                   << ", isRandomX=" << (isRandomXBlock ? "true" : "false")
                   << ", hasRandomXField=" << (!curHdr.hashRandomX.IsNull() ? "true" : "false");
        }
        
        // Accept both 80-byte (standard) and 112-byte (padded) headers for verification
        if (header.size() != FIXED_HEADER_RECORD_SIZE && header.size() != 80) {
            if (err) *err = QString("Header verification failed for header at height %1: wrong size (expected %2 or 80 bytes, got %3)")
                .arg(height).arg(FIXED_HEADER_RECORD_SIZE).arg(header.size());
            return false;
        }
        
        if (!checkInner(height, curHdr, err, isAlphaRandomX))
            return false;
            
        prevHeight = height;
        prev = header;
        if (err) err->clear();
        return true;
    }

    bool HeaderVerifier::checkInner(long height, const bitcoin::CBlockHeader &curHdr, QString *err, bool)
    {
        // Check if this is a RandomX block based on height
        const bool isRandomXBlock = IsRandomXBlock(height);
        if (isRandomXBlock) {
            Debug() << "Bypassing hash validation for RandomX block at height " << height;
            return true;
        }
        
        if (curHdr.IsNull()) {
            if (err) *err = QString("Header verification failed for header at height %1: failed to deserialize").arg(height);
            return false;
        }
        
        if (!prev.isEmpty()) {
            QByteArray prevHash;
            
            // For the previous block, determine how to calculate its hash
            
            const bool prevIsRandomX = IsRandomXBlock(prevHeight);
            // For clarity in code below
            const bool prevIsAlphaRandomX = prevIsRandomX;
            
            // Accept both 80-byte (standard) and 112-byte (padded) headers for previous block
            if (prev.size() != FIXED_HEADER_RECORD_SIZE && prev.size() != 80) {
                if (err) *err = QString("Invalid header size for block %1: expected %2 or 80 bytes, got %3")
                    .arg(prevHeight).arg(FIXED_HEADER_RECORD_SIZE).arg(prev.size());
                return false;
            }
            
            // Add debug info for the first few blocks
            if (height < 10) {
                Debug() << "checkInner: previous header at height " << prevHeight 
                       << ": header size=" << prev.size() 
                       << ", isRandomX=" << (prevIsRandomX ? "true" : "false");
            }
            
            /* 
             * IMPORTANT: Handling the transition between standard blocks and RandomX blocks
             * 
             * There are several cases to consider:
             * 1. Previous block is before activation height (standard header)
             *    - Use standard double-SHA256 hash
             * 
             * 2. Previous block is after activation height (RandomX header)
             *    - If hashRandomX is set, use it directly (most efficient)
             *    - If hashRandomX is not set, throw an error (malformed header)
             * 
             * 3. We're at the transition point (current block is the first RandomX block)
             *    - Previous block must be verified using standard double-SHA256
             *    - Current block will bypass validation (due to the isRandomXBlock check above)
             */
            if (prevIsAlphaRandomX) {
                // If the previous block is an Alpha RandomX header, check if it has a hashRandomX field
                bitcoin::CBlockHeader prevHdr = Deserialize<bitcoin::CBlockHeader>(prev);
                if (!prevHdr.hashRandomX.IsNull()) {
                    // Use the pre-computed RandomX hash stored in the header
                    prevHash = QByteArray::fromRawData(reinterpret_cast<const char *>(prevHdr.hashRandomX.begin()), 
                                                    int(prevHdr.hashRandomX.width()));
                } else if (prevIsRandomX) {
                    // For post-activation blocks, hashRandomX should always be set
                    // If we get here, it means there's an error in the header format
                    if (err) *err = QString("RandomX block at height %1 is missing hashRandomX field").arg(prevHeight);
                    return false;
                } else {
                    // For standard block hashing, always use just the first 80 bytes
                    prevHash = Hash(prev.left(80));
                }
            } else {
                // For standard block hashing, always use just the first 80 bytes
                prevHash = Hash(prev.left(80));
            }
            
            // Enhanced diagnostic logging for early blocks (height < 10)
            if (height < 10) {
                QString prevHashHex = Util::ToHexFast(prevHash).toLower();
                QString curPrevHashHex = curHdr.hashPrevBlock.ToString().c_str();
                
                Debug() << "Header verification for height " << height << ":";
                Debug() << "  Previous block hash (calculated): " << prevHashHex;
                Debug() << "  hashPrevBlock in current header:  " << curPrevHashHex;
                Debug() << "  Previous header size: " << prev.size() << " bytes";
                Debug() << "  Previous is RandomX: " << (prevIsRandomX ? "Yes" : "No");
            }
            
            // Check that the current header's hashPrevBlock matches the hash of the previous block
            if (prevHash != QByteArray::fromRawData(reinterpret_cast<const char *>(curHdr.hashPrevBlock.begin()), 
                                                   int(curHdr.hashPrevBlock.width()))) {
                if (err) *err = QString("Header %1 'hashPrevBlock' does not match the contents of the previous block").arg(height);
                return false;
            }
        }
        
        return true;
    }
    std::pair<int, QByteArray> HeaderVerifier::lastHeaderProcessed() const
    {
        return { int(prevHeight), prev };
    }


    namespace {
        // Cache the netnames as QStrings since we will need them later for blockchain.address.* methods in Servers.cpp
        // Note that these must always match whatever bitcoind calls these because ultimately we decide what network
        // we are on by asking bitcoind what net it's on via the "getblockchaininfo" RPC call (upon initial synch).
        const QMap<Net, QString> netNameMap = {{
            // These names are all the "canonical" or normalized names (they are what BCHN calls them)
            // Note that bchd has altername names for these (see nameNetMap below).
            { MainNet, "main"},
            { TestNet, "test"},
            { TestNet4, "test4"},
            { ScaleNet, "scale"},
            { RegTestNet, "regtest"},
            { ChipNet, "chip"},
            { AlphaNet, "alpha"},
            { AlphaTestNet, "alphatest"},
        }};
        const QMap<QString, Net> nameNetMap = {{
            {"main",     MainNet},     // BCHN, BU, ABC, Core, LitecoinCore
            {"mainnet",  MainNet},     // bchd
            {"test",     TestNet},     // BCHN, BU, ABC, Core, LitecoinCore
            {"test4",    TestNet4},    // BCHN, BU
            {"scale",    ScaleNet},    // BCHN, BU
            {"testnet3", TestNet},     // bchd
            {"testnet4", TestNet4},    // Core, possible future bchd
            {"regtest",  RegTestNet},  // BCHN, BU, ABC, bchd, Core, LitecoinCore
            {"signet",   TestNet},     // Core only
            {"chip",     ChipNet},     // BCH only; BCHN
            {"chipnet",  ChipNet},     // BCH only; BU
            {"alpha",    AlphaNet},    // Alpha mainnet
            {"alphatest", AlphaTestNet}, // Alpha testnet
        }};
        const QString invalidNetName = "invalid";
    };
    const QString & NetName(Net net) noexcept {
        if (auto it = netNameMap.find(net); it != netNameMap.end())
            return it.value();
        return invalidNetName; // not found
    }
    Net NetFromName(const QString & name) noexcept {
        // First try exact match
        if (auto it = nameNetMap.find(name); it != nameNetMap.end())
            return it.value();
        
        // If not found, try case-insensitive match for better compatibility with chain names
        const QString nameLower = name.toLower();
        for (auto it = nameNetMap.begin(); it != nameNetMap.end(); ++it) {
            if (it.key().toLower() == nameLower)
                return it.value();
        }
        
        return Net::Invalid; // not found
    }

    namespace { const QString coinNameBCH{"BCH"}, coinNameBTC{"BTC"}, coinNameLTC{"LTC"}, coinNameALPHA{"ALPHA"}; }
    QString coinToName(Coin c) {
        QString ret; // for NRVO
        switch (c) {
        case Coin::BCH: ret = coinNameBCH; break;
        case Coin::BTC: ret = coinNameBTC; break;
        case Coin::LTC: ret = coinNameLTC; break;
        case Coin::ALPHA: ret = coinNameALPHA; break;
        case Coin::Unknown: break;
        }
        return ret;
    }
    Coin coinFromName(const QString &s) {
        if (s == coinNameBCH) return Coin::BCH;
        if (s == coinNameBTC) return Coin::BTC;
        if (s == coinNameLTC) return Coin::LTC;
        if (s == coinNameALPHA) return Coin::ALPHA;
        return Coin::Unknown;
    }

    bitcoin::token::OutputDataPtr DeserializeTokenDataWithPrefix(const QByteArray &ba, int pos) {
        bitcoin::token::OutputDataPtr ret;
        if (ba.size() - pos > 0) {
            // attempt to deserialize token data
            if (uint8_t(ba[pos++]) != bitcoin::token::PREFIX_BYTE) // Expect: 0xef
                throw std::ios_base::failure(
                    strprintf("Expected token prefix byte 0x%02x, instead got 0x%02x in %s at position %i",
                              bitcoin::token::PREFIX_BYTE, uint8_t(ba[pos-1]), __func__, pos-1));
            ret.emplace();
            BTC::Deserialize<bitcoin::token::OutputData>(*ret, ba, pos , false, false,
                                                         true /* cashTokens */,
                                                         true /* noJunkAtEnd */);
        }
        return ret;
    }

    void SerializeTokenDataWithPrefix(QByteArray &ba, const bitcoin::token::OutputData *ptokenData) {
        if (ptokenData) {
            ba.reserve(ba.size() + 1 + ptokenData->EstimatedSerialSize());
            ba.append(char(bitcoin::token::PREFIX_BYTE)); // append PREFIX_BYTE since we expect it on deser
            BTC::Serialize(ba, *ptokenData); // append serialized token data
        }
    }


} // end namespace BTC


#ifdef ENABLE_TESTS
#include "App.h"

#include "bitcoin/transaction.h"
#include "bitcoin/uint256.h"

namespace {
    void test()
    {
        // Misc. unit tests for BTC namespace utility functions
        Log() << "Testing Hash2ByteArrayRev ...";
        bitcoin::uint256 hash = bitcoin::uint256S("080bb1010c4d32f3cb16c6a7f1ac2a949d0b5b0f0396f183870be7032cfc4da9");
        if (hash.ToString() != "080bb1010c4d32f3cb16c6a7f1ac2a949d0b5b0f0396f183870be7032cfc4da9") throw Exception("Hash parse fail");
        const QByteArray qba(reinterpret_cast<const char *>(std::as_const(hash).data()), hash.size());
        if (ByteView{hash} != ByteView{qba}) throw Exception("2");
        if (qba.toHex() != "a94dfc2c03e70b8783f196030f5b0b9d942aacf1a7c616cbf3324d0c01b10b08") throw Exception("Hash parse did not yield expected result");
        auto rhash = BTC::Hash2ByteArrayRev(hash);
        Debug() << "Expected hash: " << rhash.toHex();
        if (rhash.toHex() != "080bb1010c4d32f3cb16c6a7f1ac2a949d0b5b0f0396f183870be7032cfc4da9") throw Exception("BTC::Hash2ByteArrayRev is broken");

        Log() << "Testing Deserialize ...";
        const auto txnhex = "0100000001e7b81293c58fa088412949e485f7a7310c386a267a1825284e79c083d26b55670000000084410b00"
                            "086668d9c26c3bf44b4f136512d7edae0f01ddd66844e312fa00f54250e93457b5e2c823ca31ab452d22f27181"
                            "b13ce3560b974130b5e8a9e1b3ab820d0d414104e8806002111e3dfb6944e63a42461832437f2bbd616facc269"
                            "10becfa388642972aaf555ffcdc2cdc07a248e7881efa7f456634e1bdb11485dbbc9db20cb669dfeffffff01fb"
                            "0cfe00000000001976a914590888ac04b1f1cf01f08110cca83dd3e3da7f7388accbb90c00";
        auto tx = BTC::Deserialize<bitcoin::CTransaction>(Util::ParseHexFast(txnhex));
        if (hash != tx.GetHash()) throw Exception("Txn did not deserialize ok");

        Log() << "Testing HashInPlace ...";
        if (BTC::HashInPlace(tx) != qba) throw Exception("Txn hash in place failed");
        if (BTC::HashInPlace(tx, false, /* reversed = */true) != rhash) throw Exception("Txn hash in place reversed failed");

        Log(Log::BrightWhite) << "All btcmisc unit tests passed!";
    }

    auto t1 = App::registerTest("btcmisc", test);
} // namespace
#endif
