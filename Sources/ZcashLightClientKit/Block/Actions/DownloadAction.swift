//
//  DownloadAction.swift
//  
//
//  Created by Michal Fousek on 05.05.2023.
//

import Foundation

final class DownloadAction {
    let configProvider: CompactBlockProcessor.ConfigProvider
    let downloader: BlockDownloader
    let transactionRepository: TransactionRepository
    let logger: Logger

    init(container: DIContainer, configProvider: CompactBlockProcessor.ConfigProvider) {
        self.configProvider = configProvider
        downloader = container.resolve(BlockDownloader.self)
        transactionRepository = container.resolve(TransactionRepository.self)
        logger = container.resolve(Logger.self)
    }

    private func update(context: ActionContext) async -> ActionContext {
        await context.update(state: .scan)
        return context
    }
}

extension DownloadAction: Action {
    var removeBlocksCacheWhenFailed: Bool { true }

    func run(with context: ActionContext, didUpdate: @escaping (CompactBlockProcessor.Event) async -> Void) async throws -> ActionContext {
        guard let lastScannedHeight = await context.syncControlData.latestScannedHeight else {
            return await update(context: context)
        }

        let config = await configProvider.config
        let lastScannedHeightDB = try await transactionRepository.lastScannedHeight()
        let latestBlockHeight = await context.syncControlData.latestBlockHeight
        // This action is executed for each batch (batch size is 100 blocks by default) until all the blocks in whole `downloadRange` are downloaded.
        // So the right range for this batch must be computed.
        let batchRangeStart = max(lastScannedHeightDB, lastScannedHeight)
        let batchRangeEnd = min(latestBlockHeight, batchRangeStart + config.batchSize)

        guard batchRangeStart <= batchRangeEnd else {
            return await update(context: context)
        }

        let batchRange = batchRangeStart...batchRangeEnd
        let downloadLimit = batchRange.upperBound + (2 * config.batchSize)

        logger.debug("Starting download with range: \(batchRange.lowerBound)...\(batchRange.upperBound)")
        await downloader.update(latestDownloadedBlockHeight: batchRange.lowerBound)
        try await downloader.setSyncRange(lastScannedHeight...latestBlockHeight, batchSize: config.batchSize)
        await downloader.setDownloadLimit(downloadLimit)
        await downloader.startDownload(maxBlockBufferSize: config.downloadBufferSize)

        try await downloader.waitUntilRequestedBlocksAreDownloaded(in: batchRange)

        return await update(context: context)
    }

    func stop() async {
        await downloader.stopDownload()
    }
}
