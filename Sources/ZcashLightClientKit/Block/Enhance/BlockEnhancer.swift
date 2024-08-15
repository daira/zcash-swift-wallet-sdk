//
//  CompactBlockEnhancement.swift
//  ZcashLightClientKit
//
//  Created by Francisco Gindre on 4/10/20.
//

import Foundation

public struct EnhancementProgress: Equatable {
    /// total transactions that were detected in the `range`
    public let totalTransactions: Int
    /// enhanced transactions so far
    public let enhancedTransactions: Int
    /// last found transaction
    public let lastFoundTransaction: ZcashTransaction.Overview?
    /// block range that's being enhanced
    public let range: CompactBlockRange
    /// whether this transaction can be considered `newly mined` and not part of the
    /// wallet catching up to stale and uneventful blocks.
    public let newlyMined: Bool

    public init(
        totalTransactions: Int,
        enhancedTransactions: Int,
        lastFoundTransaction: ZcashTransaction.Overview?,
        range: CompactBlockRange,
        newlyMined: Bool
    ) {
        self.totalTransactions = totalTransactions
        self.enhancedTransactions = enhancedTransactions
        self.lastFoundTransaction = lastFoundTransaction
        self.range = range
        self.newlyMined = newlyMined
    }

    public var progress: Float {
        totalTransactions > 0 ? Float(enhancedTransactions) / Float(totalTransactions) : 0
    }

    public static var zero: EnhancementProgress {
        EnhancementProgress(totalTransactions: 0, enhancedTransactions: 0, lastFoundTransaction: nil, range: 0...0, newlyMined: false)
    }

    public static func == (lhs: EnhancementProgress, rhs: EnhancementProgress) -> Bool {
        return
            lhs.totalTransactions == rhs.totalTransactions &&
            lhs.enhancedTransactions == rhs.enhancedTransactions &&
            lhs.lastFoundTransaction?.rawID == rhs.lastFoundTransaction?.rawID &&
            lhs.range == rhs.range
    }
}

protocol BlockEnhancer {
    func enhance(at range: CompactBlockRange, didEnhance: @escaping (EnhancementProgress) async -> Void) async throws -> [ZcashTransaction.Overview]?
}

struct BlockEnhancerImpl {
    let blockDownloaderService: BlockDownloaderService
    let rustBackend: ZcashRustBackendWelding
    let transactionRepository: TransactionRepository
    let metrics: SDKMetrics
    let service: LightWalletService
    let logger: Logger

    private func enhance(txId: Data) async throws -> ZcashTransaction.Overview {
        logger.debug("Zoom.... Enhance... Tx: \(txId.toHexStringTxId())")

        let fetchedTransaction = try await blockDownloaderService.fetchTransaction(txId: txId)

        if fetchedTransaction.minedHeight == -1 {
            try await rustBackend.setTransactionStatus(txId: fetchedTransaction.rawID, status: .txidNotRecognized)
        } else if fetchedTransaction.minedHeight == 0 {
            try await rustBackend.setTransactionStatus(txId: fetchedTransaction.rawID, status: .notInMainChain)
        } else if fetchedTransaction.minedHeight > 0 {
            try await rustBackend.decryptAndStoreTransaction(
                txBytes: fetchedTransaction.raw.bytes,
                minedHeight: Int32(fetchedTransaction.minedHeight)
            )
        }

        return try await transactionRepository.find(rawID: fetchedTransaction.rawID)
    }
}

extension BlockEnhancerImpl: BlockEnhancer {
    func enhance(at range: CompactBlockRange, didEnhance: @escaping (EnhancementProgress) async -> Void) async throws -> [ZcashTransaction.Overview]? {
        try Task.checkCancellation()
        
        logger.debug("Started Enhancing range: \(range)")

        var retries = 0
        let maxRetries = 5
        
        // fetch transactions
        do {
            let startTime = Date()
            let transactionDataRequests = try await rustBackend.transactionDataRequests()

            guard !transactionDataRequests.isEmpty else {
                logger.debug("No transaction data requests detected.")
                logger.sync("No transaction data requests detected.")
                return nil
            }

            let chainTipHeight = try await blockDownloaderService.latestBlockHeight()
            let newlyMinedLowerBound = chainTipHeight - ZcashSDK.expiryOffset
            let newlyMinedRange = newlyMinedLowerBound...chainTipHeight

            for index in 0 ..< transactionDataRequests.count {
                let transactionDataRequest = transactionDataRequests[index]
                var retry = true

                while retry && retries < maxRetries {
                    try Task.checkCancellation()
                    do {
                        switch transactionDataRequest {
                        case .getStatus(let txId), .enhancement(let txId):
                            let confirmedTx = try await enhance(txId: txId.data)
                            retry = false
                            
                            let progress = EnhancementProgress(
                                totalTransactions: transactionDataRequests.count,
                                enhancedTransactions: index + 1,
                                lastFoundTransaction: confirmedTx,
                                range: range,
                                newlyMined: confirmedTx.isSentTransaction && newlyMinedRange.contains(confirmedTx.minedHeight ?? 0)
                            )

                            await didEnhance(progress)
                        case .spendsFromAddress(let sfa):
                            var filter = TransparentAddressBlockFilter()
                            filter.address = sfa.address
                            filter.range = BlockRange(startHeight: Int(sfa.blockRangeStart), endHeight: Int(sfa.blockRangeEnd))
                            let stream = service.getTaddressTxids(filter)

                            for try await rawTransaction in stream {
                                try await rustBackend.decryptAndStoreTransaction(
                                    txBytes: rawTransaction.data.bytes,
                                    minedHeight: Int32(rawTransaction.height)
                                )
                            }
                            retry = false
                        }
                    } catch {
                        retries += 1
                        logger.error("could not enhance transactionDataRequest \(transactionDataRequest) - Error: \(error)")
                        if retries > maxRetries {
                            throw error
                        }
                    }
                }
            }
            
            let endTime = Date()
            let diff = endTime.timeIntervalSince1970 - startTime.timeIntervalSince1970
            let logMsg = "Enhanced \(transactionDataRequests.count) transaction data requests in \(diff)"
            logger.sync(logMsg)
            metrics.actionDetail(logMsg, for: .enhance)
        } catch {
            logger.error("error enhancing transactions! \(error)")
            throw error
        }
        
        if Task.isCancelled {
            logger.debug("Warning: compactBlockEnhancement on range \(range) cancelled")
        }

        return (try? await transactionRepository.find(in: range, limit: Int.max, kind: .all))
    }
}
