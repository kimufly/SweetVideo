import { FileFolder } from '../interfaces/FileFolderInterface'
import { VideoMetadata } from '../interfaces/VideoMetadataInterface'
import FileFolderUtil from './FileFolderUtil'
import SelectFileUtil from './SelectFileUtil'
import ToolsUtil from './ToolsUtil'
import { salmonLogger } from 'salmonlogger'
import { extractVideoMetadataInTaskPool, MetadataExtractionResult } from './TaskpoolUtil'

const TAG = 'FileProcessorUtil'

// 进度信息接口
export interface ProgressInfo {
  current: number // 当前处理的文件索引
  total: number // 总文件数
  fileName: string // 当前处理的文件名
  stage: 'extracting' | 'cover' | 'saving' // 当前阶段
  speed: number // 处理速度（个/秒）
  elapsedTime: number // 已耗时（毫秒）
  failedCount: number // 失败文件数
}

// 独立文件处理工具类
export class FileProcessorUtil {
  // 获取视频封面和处理文件的最大并发数
  public static MAX_CONCURRENT = 12
  // 失败文件列表
  public static failedFiles: string[] = []

  // 批量导入优化：先并行提取所有元数据（TaskPool 最大化利用），再串行处理每个文件
  public static async processFilesConcurrently(
    fileList: string[],
    context: Context,
    sandbox_video: string,
    sandbox_path: string,
    video_meta_data: VideoMetadata[],
    progressCallback: (info: ProgressInfo) => void,
    fileFolder?: FileFolder
  ): Promise<void> {
    if (fileList.length === 0) {
      ToolsUtil.showToast('没有任何文件被导入哦~')
      return
    }
    FileFolderUtil.duplicateVideo = 0
    FileProcessorUtil.failedFiles = []

    const startTime = Date.now()
    let processedCount = 0
    let failedCount = 0

    // 阶段1: 并行提取所有文件的元数据（TaskPool 最大化利用）
    progressCallback({
      current: 0,
      total: fileList.length,
      fileName: '提取元数据中...',
      stage: 'extracting',
      speed: 0,
      elapsedTime: 0,
      failedCount: 0
    })

    const extractionTasks: Promise<MetadataExtractionResult>[] = fileList.map(uri =>
      extractVideoMetadataInTaskPool(uri)
    )
    const extractionResults: MetadataExtractionResult[] = await Promise.all(extractionTasks)

    // 阶段2: 使用预提取的元数据串行处理每个文件（避免逐文件等待 TaskPool）
    for (let i = 0; i < fileList.length; i++) {
      const uri = fileList[i]
      const result = extractionResults[i]
      const fileName = result.fileName || uri.split('/')[uri.split('/').length - 1]

      progressCallback({
        current: i + 1,
        total: fileList.length,
        fileName: fileName,
        stage: 'extracting',
        speed: i / ((Date.now() - startTime) / 1000),
        elapsedTime: Date.now() - startTime,
        failedCount: failedCount
      })

      try {
        await SelectFileUtil.processSingleFileWithMetadata(
          uri,
          context,
          sandbox_video,
          sandbox_path,
          video_meta_data,
          result,
          fileFolder
        )
      } catch (error) {
        FileProcessorUtil.failedFiles.push(uri)
        failedCount++
        salmonLogger.addLog(TAG, `处理文件失败: ${fileName}, 错误: ${error}`, true)
      }

      processedCount++

      progressCallback({
        current: processedCount,
        total: fileList.length,
        fileName: fileName,
        stage: 'saving',
        speed: processedCount / ((Date.now() - startTime) / 1000),
        elapsedTime: Date.now() - startTime,
        failedCount: failedCount
      })
    }
  }

  // 智能分块算法：按文件大小和数量优化分块，提高负载均衡
  static splitListIntoChunks(list: string[]): string[][] {
    const chunks: string[][] = []
    const chunkCount = Math.min(FileProcessorUtil.MAX_CONCURRENT, list.length) // 实际需要分块数

    // 如果文件数量较少，使用简单的平均分块
    if (list.length <= chunkCount * 2) {
      const baseSize = Math.floor(list.length / chunkCount)
      const remainder = list.length % chunkCount

      let start = 0
      for (let i = 0; i < chunkCount; i++) {
        const extra = i < remainder ? 1 : 0
        const end = start + baseSize + extra
        chunks.push(list.slice(start, end))
        start = end
      }
    } else {
      // 文件数量较多时，使用交错分配策略，确保每个块的负载均衡
      // 这样可以避免某些块处理大文件集合，而其他块处理小文件集合
      for (let i = 0; i < chunkCount; i++) {
        chunks.push([])
      }

      // 交错分配文件到各个块
      for (let i = 0; i < list.length; i++) {
        const chunkIndex = i % chunkCount
        chunks[chunkIndex].push(list[i])
      }
    }

    return chunks
  }
}

export class ConcurrencyManagerUtil {
  // 文件操作队列（按URI分组）
  private static fileQueues: Map<string, AsyncQueue> = new Map()
  // 全局锁存储
  private static locks: Map<string, MutexLock> = new Map()

  // 获取文件操作队列
  static getFileQueue(uri: string): AsyncQueue {
    if (!ConcurrencyManagerUtil.fileQueues.has(uri)) {
      ConcurrencyManagerUtil.fileQueues.set(uri, new AsyncQueue())
    }
    return ConcurrencyManagerUtil.fileQueues.get(uri)!
  }

  // 获取互斥锁
  static getLock(key: string): MutexLock {
    if (!ConcurrencyManagerUtil.locks.has(key)) {
      ConcurrencyManagerUtil.locks.set(key, new MutexLock())
    }
    return ConcurrencyManagerUtil.locks.get(key)!
  }

  // 标准化URI（去掉查询参数等差异）
  static normalizeUri(uri: string): string {
    const queryIndex = uri.indexOf('?')
    if (queryIndex > 0) {
      return uri.substring(0, queryIndex)
    }
    return uri
  }
}

// 实现一个串行的异步队列
class AsyncQueue {
  private tasks: (() => Promise<void>)[] = []
  private running = false

  async run(task: () => Promise<void>): Promise<void> {
    return new Promise((resolve, reject) => {
      const wrappedTask = async () => {
        try {
          await task()
          resolve()
        } catch (e) {
          reject(e)
        } finally {
          this.running = false
          this.runNext()
        }
      }

      this.tasks.push(wrappedTask)
      if (!this.running) {
        this.runNext()
      }
    })
  }

  private runNext() {
    if (this.tasks.length > 0) {
      this.running = true
      const task = this.tasks.shift()!
      task()
    }
  }
}

// 互斥锁实现
class MutexLock {
  private locked = false
  private queue: (() => void)[] = []

  async acquire(): Promise<void> {
    if (!this.locked) {
      this.locked = true
      return
    }
    return new Promise(resolve => this.queue.push(resolve))
  }

  release(): void {
    if (this.queue.length > 0) {
      const next = this.queue.shift()!
      next()
    } else {
      this.locked = false
    }
  }
}