import { common, ConfigurationConstant, Context } from '@kit.AbilityKit'
import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit'
import VideoInfoUtil from './VideoInfoUtil'
import { media } from '@kit.MediaKit'
import { SaveOptions, VideoMetadata } from '../interfaces/VideoMetadataInterface'
import { FileFolder } from '../interfaces/FileFolderInterface'
import ToolsUtil from './ToolsUtil'
import { image } from '@kit.ImageKit'
import PermissionUtil from './PermissionUtil'
import { VideoSource } from '../common/enum/VideoSource'
import { salmonLogger } from 'salmonlogger'
import { SUPPORT_AUDIO_FORMAT, SUPPORT_VIDEO_FORMAT } from '../common/Constants'
import Preferences from '../database/Preferences'
import FileFolderUtil from './FileFolderUtil'
import { ConcurrencyManagerUtil } from './FileProcessorUtil'
import { PathUtils } from './PathUtils'
import PrivacySpaceUtil from './PrivacySpaceUtil'
import RecentPlayUtil from './RecentPlayUtil'
import SubtitleUtil from './SubtitleUtil'
import { coverEventBus } from './CoverEventUtil'
import { extractVideoMetadataInTaskPool } from './TaskpoolUtil'
import { systemDateTime } from '@kit.BasicServicesKit'
import { PrivacyVideoRepository } from '../repository/PrivacyVideoRepository'
import { VideoRepository } from '../repository/VideoRepository'
import { RecentPlayRepository } from '../repository/RecentPlayRepository'
import { FolderRepository } from '../repository/FolderRepository'
import { VideoEntity } from '../entity/VideoEntity'
import { PrivacyVideoEntity } from '../entity/PrivacyVideoEntity'

const TAG = 'SelectFileUtil'

export default class SelectFileUtil {
  public static fileFolderUri = ''
  public static videoSourcePath = new Map<number, string>([
    [VideoSource.SWEET_VIDEO_DOWNLOAD_FILE, '/storage/Users/currentUser/'],
    [VideoSource.DOCUMENT_SELECT_OPTION, 'file://docs/storage/Users'],
    [VideoSource.PHOTO_SELECT_OPTION, 'file://media/Photo'],
    [VideoSource.PRIVACY_SPACE, '/data/storage/el2'],
    [VideoSource.EXTERNAL_DEVICE, 'file://docs/storage/External']
  ])
  private static queryCache = new WeakMap<VideoMetadata[], Map<string, VideoMetadata>>()

  static async selectFromFileManager(uri?: string, mode: 'video' | 'audio' | 'both' = 'both'): Promise<string[]> {
    const documentSelectOptions = new picker.DocumentSelectOptions()
    if (uri) {
      documentSelectOptions.defaultFilePathUri = uri
    }
    // 根据模式设置文件过滤器
    switch (mode) {
      case 'video':
        documentSelectOptions.fileSuffixFilters = SUPPORT_VIDEO_FORMAT
        break
      case 'audio':
        documentSelectOptions.fileSuffixFilters = SUPPORT_AUDIO_FORMAT
        break
      case 'both':
      default:
        documentSelectOptions.fileSuffixFilters = SUPPORT_VIDEO_FORMAT.concat(SUPPORT_AUDIO_FORMAT)
        break
    }
    // 如果没有指定uri，根据模式设置合并模式
    if (!uri) {
      switch (mode) {
        case 'video':
          documentSelectOptions.mergeMode = picker.MergeTypeMode.VIDEO
          break
        case 'audio':
          documentSelectOptions.mergeMode = picker.MergeTypeMode.AUDIO
          break
        case 'both':
        default:
        // 对于both模式，可以选择不设置mergeMode或设置为一个默认值
        // 根据你的需求调整
          break
      }
    }
    const documentViewPicker = new picker.DocumentViewPicker(PathUtils.appContext!)
    try {
      const documentSelectResult: string[] = await documentViewPicker.select(documentSelectOptions)
      return documentSelectResult.length > 0 ? documentSelectResult : []
    } catch (error) {
      salmonLogger.addLog(TAG, "Error selecting files: " + error, true)
      return []
    }
  }

  static async selectPhoto(): Promise<string[]> {
    return SelectFileUtil.selectFromAlbum(photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE, 1)
  }

  static async deletePhoto(imageName: 'BackgroundImage' | 'BackgroundDarkImage') {
    fs.access(PathUtils.photoPath! + imageName).then((res: boolean) => {
      if (res) {
        fs.unlink(PathUtils.photoPath! + imageName, async (unlinkErr) => {
          if (unlinkErr) {
            ToolsUtil.showToast('删除自定义背景失败，原因是：' + unlinkErr.message)
          }
          ToolsUtil.showToast('删除自定义背景成功')
        })
      } else {
        salmonLogger.addLog(TAG, "自定义背景不存在", true)
      }
    })?.catch((err: BusinessError) => {
      salmonLogger.addLog(TAG, "access failed with error message: " + err.message + ", error code: " + err.code, true)
    })
  }

  // 获取下载文件夹路径
  static async getDownloadUri() {
    const documentViewPicker = new picker.DocumentViewPicker()
    let documentSaveResult = await documentViewPicker.save({ pickerMode: picker.DocumentPickerMode.DOWNLOAD })
    const uri = new fileUri.FileUri(documentSaveResult[0])
    SelectFileUtil.fileFolderUri = uri.path
  }

  // 导出视频文件
  static async exportFile(uri: string, title: string, format: string, context: common.UIAbilityContext) {
    let sourceFile: fs.File | null = null
    let targetFile: fs.File | null = null
    try {
      sourceFile = fs.openSync(uri, fs.OpenMode.READ_ONLY)
      const saverOption = new picker.DocumentSaveOptions()
      saverOption.newFileNames = SelectFileUtil.copyFileReName(title, format)
      const documentSaveResult = await new Promise<string[]>((resolve, reject) => {
        const saver = new picker.DocumentViewPicker(context)
        saver.save(saverOption, (err: BusinessError, uris: string[]) => {
          err ? reject(err) : resolve(uris)
        })
      })
      targetFile = fs.openSync(documentSaveResult[0], fs.OpenMode.READ_WRITE)
      await fs.copyFile(sourceFile.fd, targetFile.fd)
      ToolsUtil.showToast(`导出成功: ${targetFile?.name} 路径为: ${targetFile?.path}`)
    } catch (error) {
      ToolsUtil.showToast(`导出失败，原因是：${error}`)
    } finally {
      if (sourceFile) {
        fs.closeSync(sourceFile.fd)
      }
      if (targetFile) {
        fs.closeSync(targetFile.fd)
      }
    }
  }

  static getImageUri(): string {
    const currentColorMode = AppStorage.get('currentColorMode') as number
    const basePhotoPath = PathUtils.photoPath!
    // 辅助函数：安全地获取文件 URI
    // 如果文件存在返回 URI，否则返回空字符串
    const getSafeUri = (fileName: string): string => {
      const fullPath = `${basePhotoPath}${fileName}`
      try {
        if (fs.accessSync(fullPath)) {
          return fileUri.getUriFromPath(fullPath)
        }
      } catch (e) {
        // accessSync 抛出异常通常意味着权限问题或路径严重错误，视为文件不存在
        salmonLogger.addLog(TAG, `Failed to access image: ${fullPath} ` + e)
      }
      return ''
    }
    try {
      // 1. 处理亮色模式
      if (currentColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
        return getSafeUri('BackgroundImage')
      }
      // 2. 处理暗色模式
      if (currentColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
        // 优先尝试获取暗色背景
        const darkUri = getSafeUri('BackgroundDarkImage')
        if (darkUri) {
          return darkUri
        }
        // 降级策略：如果暗色背景不存在，尝试返回亮色背景
        return getSafeUri('BackgroundImage')
      }
      // 3. 其他未定义的模式，默认返回空或根据需求返回亮色图
      return ''
    } catch (error) {
      // 捕获顶层意外错误（如 AppStorage 读取失败等）
      salmonLogger.addLog(TAG, 'Unexpected error in getImageUri' + error, true)
      return ''
    }
  }

  static saveImageToPrivacySpace(sourceFileUri: string, isDark: boolean) {
    const filePath = PathUtils.photoPath + (isDark ? 'BackgroundDarkImage' : 'BackgroundImage') // 定义完整文件路径
    try {
      let sourceFile = fs.openSync(sourceFileUri, fs.OpenMode.READ_ONLY)
      let targetFile = fs.openSync(filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE)

      fs.copyFileSync(sourceFile.fd, targetFile.fd)

      fs.closeSync(sourceFile)
      fs.closeSync(targetFile)
    } catch (error) {
      salmonLogger.addLog(TAG, 'File operation error:' + error, true)
    }
  }

  // 保存封面，封面获取后复制到应用私有目录下
  static async saveVideoImageToSandBox(sandbox_path: string, date: string, pixelMap: image.PixelMap) {
    const filePath = sandbox_path + date
    let packer: image.ImagePacker | undefined = undefined
    let file: fs.File | undefined = undefined
    try {
      packer = image.createImagePacker()
      file = fs.openSync(filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE)
      await packer.packToFile(pixelMap, file.fd, { format: 'image/webp', quality: 85 })
    } catch (error) {
      const err = error as BusinessError
      salmonLogger.addLog(TAG, `Failed to save cover: code ${err.code}, message: ${err.message}`, true)
      // 删除可能损坏的文件
      try {
        fs.accessSync(filePath) && fs.unlinkSync(filePath)
      } catch {
        // 忽略删除错误
      }
      // 不抛出异常，由调用方通过其他方式检测封面是否存在
    } finally {
      // 确保资源释放
      if (file) {
        try {
          fs.closeSync(file)
        } catch (e) {
          salmonLogger.addLog(TAG, 'Failed to close file: ' + e, false)
        }
      }
      if (packer) {
        try {
          packer.release()
        } catch (e) {
          salmonLogger.addLog(TAG, 'Failed to release packer: ' + e, false)
        }
      }
      // 释放 pixelMap
      try {
        pixelMap.release()
      } catch (e) {
        salmonLogger.addLog(TAG, 'Failed to release pixelMap: ' + e, false)
      }
    }
  }

  //复制视频进入隐私空间（优化版：减少文件打开次数）
  static async copyFileToPrivacySpace(context: Context, video_meta_data_encryption: VideoMetadata[], uri: string,
    sandbox_video: string, sandbox_path: string, date: string, metadata: media.AVMetadata,
    fileName: string, fileSize: number, pixelMap: image.PixelMap | undefined): Promise<VideoMetadata> {
    let sourceFile: fs.File | null = null
    let targetFile: fs.File | null = null
    try {
      const sourceFile = fs.openSync(uri, fs.OpenMode.READ_ONLY)
      const targetPath = `${sandbox_video}${date}`
      const targetFile = fs.openSync(targetPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE)
      await new Promise<void>((resolve, reject) => {
        fs.copyFile(sourceFile.fd, targetFile.fd, (error) => {
          error ? reject(error) : resolve()
        })
      })
      const videoInfo =
        await VideoInfoUtil.setVideoInfoOptimized(date, targetPath, fileName, metadata, sandbox_video, sandbox_path,
          fileSize, pixelMap)
      // 通知 UI 封面已就绪，触发对应列表项刷新
      coverEventBus.emit('coverReady', { date: videoInfo.date })
      // ORM 改造：隐私空间视频直接插入 PrivacyVideoRepository，不再通过 Preferences 数组存储
      const privacyRepo = PrivacyVideoRepository.getInstance()
      const entity = new PrivacyVideoEntity()
      entity.uri = videoInfo.uri
      entity.title = videoInfo.title
      entity.pinyin = FileFolderUtil.computePinyin(videoInfo.title)
      entity.originalUri = videoInfo.uri
      entity.date = videoInfo.date
      entity.width = videoInfo.size[0] || 0
      entity.height = videoInfo.size[1] || 0
      entity.duration = videoInfo.time
      entity.lastPosition = videoInfo.last_play
      entity.format = videoInfo.format
      entity.fileSize = videoInfo.video_size
      entity.hdrType = videoInfo.hdr_type
      entity.startTime = videoInfo.start_time
      entity.endTime = videoInfo.end_time
      entity.pointA = videoInfo.pointA
      entity.pointB = videoInfo.pointB
      entity.subtitle_mode = videoInfo.subtitle_mode ?? 0
      entity.subtitle_visible = videoInfo.subtitle_visible !== false
      entity.subtitle_ai_asr_shown = videoInfo.subtitle_ai_asr_shown || false
      entity.subtitle_3d_mode = videoInfo.subtitle_3d_mode ?? 0
      entity.subtitle_offset_millis = videoInfo.subtitle_offset_millis ?? 0
      entity.subtitle_track_id = videoInfo.subtitle_track_id ?? 0
      await privacyRepo.insert(entity)
      video_meta_data_encryption.push(videoInfo)
      return videoInfo // 返回新创建的元数据对象
    } catch (error) {
      salmonLogger.addLog(TAG, `文件复制失败: ${uri}: error ${error}`, true)
      throw new Error(`隐私空间复制失败: ${error.message}`)
    } finally {
      fs.closeSync(sourceFile)
      fs.closeSync(targetFile)
    }
  }

  static copyFileReName(title: string, format: string) {
    return [title.split('.')[title.split('.').length - 1]
      == format ? title : title + '.' + format]
  }

  // 保存播放进度、AB 点、字幕等数据
  // ORM 改造：分别更新隐私空间/普通视频/最近播放三张表
  // 注意：不再通过 Preferences 保存整个数组，而是按 uri 精准定位单条记录并局部更新，避免并发覆盖问题
  static async saveData(context: Context, target_data: VideoMetadata, options: SaveOptions): Promise<void> {
    ToolsUtil.addLogger('开始保存播放数据', false, undefined, TAG)
    let save_time: number = 0
    if (target_data.time === 0 && options.totalTime) {
      target_data.time = options.totalTime
    }
    if (options.playTime) {
      const totalDuration = target_data?.time
      const endTime = target_data?.end_time
      let shouldMarkAsWatched = false
      if (totalDuration && options.playTime > totalDuration * 0.95) {
        shouldMarkAsWatched = true
        ToolsUtil.addLogger('播放进度超过95%，标记为已观看', false, undefined, TAG)
      } else if (endTime > 0 && options.playTime >= endTime) {
        shouldMarkAsWatched = true
        ToolsUtil.addLogger('播放至指定结束时间，标记为已观看', false, undefined, TAG)
      }
      save_time = shouldMarkAsWatched ? totalDuration : options.playTime
    }

    const updateEntity = (entity: PrivacyVideoEntity | VideoEntity) => {
      if (options.playTime) {
        entity.lastPosition = save_time
      }
      if (options.startTime) {
        entity.startTime = options.startTime
      }
      if (options.endTime) {
        entity.endTime = options.endTime
      }
      if (options.size?.[0]) {
        entity.width = options.size[0]
        entity.height = options.size[1]
      }
      if (options.totalTime && entity.duration === 0) {
        entity.duration = options.totalTime
      }
      if (options.pointA) {
        entity.pointA = options.pointA
      }
      if (options.pointB) {
        entity.pointB = options.pointB
      }
      if (options.subtitleMode !== undefined) {
        entity.subtitle_mode = options.subtitleMode
      }
      if (options.subtitleVisible !== undefined) {
        entity.subtitle_visible = options.subtitleVisible
      }
      if (options.subtitleAIAsrShown !== undefined) {
        entity.subtitle_ai_asr_shown = options.subtitleAIAsrShown
      }
      if (options.subtitle3DMode !== undefined) {
        entity.subtitle_3d_mode = options.subtitle3DMode
      }
      if (options.subtitleOffsetMillis !== undefined) {
        entity.subtitle_offset_millis = options.subtitleOffsetMillis
      }
      if (options.subtitleTrackId !== undefined) {
        entity.subtitle_track_id = options.subtitleTrackId
      }
    }

    if (PrivacySpaceUtil.getPrivacyMode()) {
      ToolsUtil.addLogger('当前处于隐私空间，更新隐私空间数据', false, undefined, TAG)
      const privacyRepo = PrivacyVideoRepository.getInstance()
      const entities = await privacyRepo.query().where({ uri: target_data.uri }).find()
      const entity = entities.length > 0 ? entities[0] : undefined
      if (entity) {
        updateEntity(entity)
        await privacyRepo.save(entity)
        ToolsUtil.addLogger('隐私空间数据更新完成', false, undefined, TAG)
      } else {
        ToolsUtil.addLogger('未在隐私空间中找到目标视频数据', true, undefined, TAG)
      }
      return
    }

    ToolsUtil.addLogger('更新文件夹中的视频数据', false, undefined, TAG)
    const videoRepo = VideoRepository.getInstance()
    const entities = await videoRepo.query().where({ uri: target_data.uri }).find()
    const entity = entities.length > 0 ? entities[0] : undefined
    if (entity) {
      updateEntity(entity)
      await videoRepo.save(entity)
    }
    ToolsUtil.addLogger('文件夹数据更新完成', false, undefined, TAG)

    ToolsUtil.addLogger('更新最近播放列表数据', false, undefined, TAG)
    const recentRepo = RecentPlayRepository.getInstance()
    const recentEntities = await recentRepo.query().where({ uri: target_data.uri }).find()
    const recentEntity = recentEntities.length > 0 ? recentEntities[0] : undefined
    if (recentEntity) {
      if (options.playTime) {
        recentEntity.lastPosition = save_time
      }
      await recentRepo.save(recentEntity)
    }
    ToolsUtil.addLogger('最近播放列表更新完成', false, undefined, TAG)
  }

  static async deleteVideo(videoMetaData: VideoMetadata) {
    await SelectFileUtil.deleteVideoFromFolder(videoMetaData)
    SelectFileUtil.deleteVideoEncryption(videoMetaData)
    RecentPlayUtil.delData(PathUtils.appContext!, videoMetaData.uri)
  }

  // 从文件夹中删除指定视频
  // ORM 改造：通过 VideoRepository 按实体删除，不再操作 Preferences 中的数组
  static async deleteVideoFromFolder(videoMetaData: VideoMetadata, currentFolder?: FileFolder) {
    const videoRepo = VideoRepository.getInstance()
    const folderRepo = FolderRepository.getInstance()

    if (currentFolder) {
      // 如果有指定文件夹，只从该文件夹删除
      const folder = await folderRepo.findByDate(currentFolder.date)
      if (folder && folder.videos) {
        const videoToDelete = folder.videos.find(v => v.date === videoMetaData.date)
        if (videoToDelete) {
          await videoRepo.delete(videoToDelete)
        }
      }
    } else {
      // 否则从所有文件夹中查找并删除
      const folders = await folderRepo.findAllWithVideos()
      for (const folder of folders) {
        if (folder.videos) {
          const videoToDelete = folder.videos.find(v => v.date === videoMetaData.date)
          if (videoToDelete) {
            await videoRepo.delete(videoToDelete)
          }
        }
      }
    }
  }

  static async deleteVideoEncryption(videoMetaData: VideoMetadata) {
    // 更新隐私空间的数据 - 使用 Repository 删除
    const privacyRepo = PrivacyVideoRepository.getInstance()
    try {
      // 根据 date 查找视频实体
      const entities = await privacyRepo.query().where({ date: videoMetaData.date }).find()
      if (entities.length > 0) {
        await privacyRepo.delete(entities[0])
        salmonLogger.addLog(TAG, `隐私空间视频已删除: ${videoMetaData.title}`, false)
      }
    } catch (error) {
      salmonLogger.addLog(TAG, `删除隐私空间视频失败: ${error}`, true)
    }

    // 删除物理文件
    fs.access(PathUtils.videoPath + videoMetaData.date).then((res: boolean) => {
      if (res) {
        fs.unlink(PathUtils.videoPath + videoMetaData.date, async (unlinkErr) => {
          if (unlinkErr) {
            ToolsUtil.showToast('删除视频失败：' + videoMetaData.title + '原因是：' + unlinkErr.message)
          }
        })
      }
    })?.catch((err: BusinessError) => {
      salmonLogger.addLog(TAG, "access failed with error message: " + err.message + ", error code: " + err.code, true)
    })
  }

  static getItem(list: VideoMetadata[], item: string): VideoMetadata | undefined {
    if (!list || !item) {
      return undefined
    }
    if (!SelectFileUtil.queryCache.has(list)) {
      SelectFileUtil.queryCache.set(list, new Map())
    }
    const listCache = SelectFileUtil.queryCache.get(list)!
    if (listCache.has(item)) {
      return listCache.get(item)
    }
    const dateMap = new Map(list.map(i => [i.date, i]))
    const foundItem = dateMap.get(item)
    if (foundItem) {
      const typedListCache: Map<string, VideoMetadata> = listCache
      typedListCache.set(item, foundItem)
      if (typedListCache.size > (list.length >= 100 ? 100 : list.length * 0.5)) {
        const iterator: IterableIterator<string> = typedListCache.keys()
        const oldestEntry: IteratorResult<string, undefined> = iterator.next()
        if (!oldestEntry.done) {
          const oldestKey: string = oldestEntry.value
          typedListCache.delete(oldestKey)
        }
      }
    }
    return foundItem
  }

  public static async getVideoListByVideoDate(videoDate: string): Promise<[VideoMetadata | undefined, VideoMetadata[]]> {
    const videoRepo = VideoRepository.getInstance()
    const videos = await videoRepo.query().where({ date: videoDate }).find()
    if (videos.length > 0) {
      return [FileFolderUtil.toVideoMetadata(videos[0]), videos.map(v => FileFolderUtil.toVideoMetadata(v))]
    }
    return [undefined, []]
  }

  // 获取下一个视频
  static getNextItem(list: VideoMetadata[], date: string) {
    const currentIndex = list.findIndex(i => i.date === date)
    if (currentIndex === -1) {
      return list[0]
    } // 如果没有找到当前项，返回 第一项
    let nextIndex = (currentIndex + 1) % list.length
    for (let i = 0; i < list.length; i++) {
      if (VideoInfoUtil.videoWidthAndHeightFormat(String(list[nextIndex].size)) !== '0 x 0') {
        return list[nextIndex]
      }
      nextIndex = (nextIndex + 1) % list.length // 移动到下一个索引
    }
    return list[(currentIndex + 1) % list.length] // 如果没有找到有效项，返回下一个项，0x0会自动调用其他播放核心
  }

  // 判断是否为最后一个视频
  static isLastItem(list: VideoMetadata[], date: string) {
    const currentIndex = list.findIndex(i => i.date === date)
    if (currentIndex === -1) {
      return true
    }
    return (list.length - 1) === currentIndex
  }

  static getItemFromSearch(list: VideoMetadata[], value: string): VideoMetadata[] {
    const trimmedValue = value?.trim()
    if (!trimmedValue) {
      return []
    }
    const lowerValue = trimmedValue.toLowerCase()
    return list.filter(item =>
    item.title.toLowerCase().includes(lowerValue)
    )
  }

  static getItemIndex(list: VideoMetadata[], tmp: VideoMetadata) {
    return list.findIndex(i => i.date == tmp.date)
  }

  static isPathFromSource(path: string | undefined, key: VideoSource) {
    const prefix = SelectFileUtil.videoSourcePath.get(key)
    if (!path || !prefix) {
      return false
    }
    // 标准化路径比较
    const normalizedPath = path.replace(/\\/g, '/')
    const normalizedPrefix = prefix.replace(/\\/g, '/')
    return normalizedPath.startsWith(normalizedPrefix)
  }

  // 检查文件是否存在
  static async isFileExist(uri: string, showToast: boolean) {
    await PermissionUtil.activatePermission(uri)
    if (SelectFileUtil.isPathFromSource(uri, VideoSource.EXTERNAL_DEVICE)) {
      ToolsUtil.showToast('文件需要重新授权才能继续播放，请点击确定予以授权')
      await SelectFileUtil.selectFromFileManager(uri)
    }
    try {
      await fs.open(String(uri), fs.OpenMode.READ_ONLY)
      return true
    } catch (e) {
      if (showToast) {
        ToolsUtil.showToast(uri + '文件已经失效，请重新导入')
        salmonLogger.addLog('file error', 'file error: ' + e.code + ':' + e.message, true)
      }
      return false
    }
  }

  static async addFile(context: Context, sandbox_video: string, sandbox_path: string, uri: string,
    video_meta_data: VideoMetadata[], file_folder?: FileFolder) {
    if (canIUse('SystemCapability.Multimedia.Media.AVMetadataExtractor')) {
      // 1. 权限持久化（主线程）
      await PermissionUtil.persistPermission(uri)

      try {
        // 2. 使用 TaskPool 提取元数据（后台线程，性能优化）
        const extractionResult = await extractVideoMetadataInTaskPool(uri)

        if (!extractionResult.success) {
          salmonLogger.addLog(TAG, 'TaskPool 元数据提取失败: ' + extractionResult.error, true)
          return
        }

        // 不使用解构赋值，逐个获取属性
        const metadata = extractionResult.metadata
        const pixelMap = extractionResult.pixelMap
        const fileSize = extractionResult.fileSize
        const fileName = extractionResult.fileName

        // 3. 数据处理和保存（主线程）
        const fileQueue = ConcurrencyManagerUtil.getFileQueue(uri)
        await fileQueue.run(async () => {
          // 获取全局数据锁（保证原子操作）
          const dataLock = ConcurrencyManagerUtil.getLock('global_data')
          await dataLock.acquire()
          try {
            if (!file_folder) {
              const folderName = FileFolderUtil.extractRootFolderNameFromUri(uri, fileName)
              if (folderName) {
                const folderLock = ConcurrencyManagerUtil.getLock(`folder_${folderName}`)
                await folderLock.acquire()
                try {
                  const folderRepo = FolderRepository.getInstance()
                  const latestFolders = await folderRepo.findAllWithVideos()
                  const existingFolder = latestFolders.find(i => i.name === folderName)
                  if (!existingFolder) {
                    const newFolders = await FileFolderUtil.createNewFolder(context, folderName)
                    file_folder = newFolders.find(item => item.name === folderName)
                  } else {
                    file_folder = FileFolderUtil.toFileFolder(existingFolder)
                  }
                } finally {
                  folderLock.release()
                }
              }
            }
            const isDuplicate = await FileFolderUtil.existsVideoInFolders(context, uri, fileName)
            if (!isDuplicate) {
              if (PrivacySpaceUtil.getPrivacyMode()!) {
                await SelectFileUtil.copyFileToPrivacySpace(context, video_meta_data, uri, sandbox_video,
                  sandbox_path, systemDateTime.getTime(true).toString(), metadata!, fileName, fileSize, pixelMap)
              } else {
                const videoInfo =
                  await VideoInfoUtil.setVideoInfoOptimized(systemDateTime.getTime(true).toString(), uri, fileName,
                    metadata!, sandbox_video, sandbox_path, fileSize, pixelMap)
                // 通知 UI 封面已就绪，触发对应列表项刷新
                coverEventBus.emit('coverReady', { date: videoInfo.date })
                // ORM 改造：将视频保存到数据库
                const folderRepo = FolderRepository.getInstance()
                const targetFolder = file_folder
                  ? await folderRepo.findByDate(file_folder.date)
                  : (await folderRepo.findAllWithVideos())[0]
                if (targetFolder && targetFolder.id !== undefined) {
                  const videoEntity = FileFolderUtil.toVideoEntity(videoInfo, targetFolder.id)
                  const videoRepo = VideoRepository.getInstance()
                  await videoRepo.insert(videoEntity)
                }
              }
            }
          } finally {
            dataLock.release()
          }
        })
      } catch (error) {
        salmonLogger.addLog(TAG, '导入视频发生错误, 原因是：' + error, true)
      }
    }
  }

  static async processSingleFile(uri: string, context: Context, sandbox_video: string, sandbox_path: string,
    video_meta_data: VideoMetadata[], fileFolder?: FileFolder): Promise<void> {
    await SelectFileUtil.addFile(
      context,
      sandbox_video,
      sandbox_path,
      uri,
      video_meta_data,
      fileFolder
    )
  }

  static async deletePrivacyVideo(date: string, title: string) {
    await SelectFileUtil.deleteCover(date)
    await SubtitleUtil.deleteSubtitle(PathUtils.subtitlePath, date)
    // ORM 改造：从 PrivacyVideoRepository 中删除对应记录
    const privacyRepo = PrivacyVideoRepository.getInstance()
    const entity = await privacyRepo.findByDate(date)
    if (entity) {
      await privacyRepo.delete(entity)
    }
    try {
      await fs.unlink(PathUtils.videoPath + date)
      ToolsUtil.showToast('删除成功')
    } catch (err) {
      const error = err as BusinessError
      if (error.code === 13900002) { // 文件或目录不存在错误码
        salmonLogger.addLog(TAG, 'file not exist', false)
      } else {
        salmonLogger.addLog(TAG, 'delete failed: ' + error.code + ':' + error.message, true)
      }
      ToolsUtil.showToast('删除视频失败：' + title + '原因是：' + err)
    }
  }

  // 删除封面
  static async deleteCover(date: string) {
    await new Promise<void>((resolve, reject) => {
      fs.access(PathUtils.coverPath + date, (err) => {
        if (!err) {
          fs.unlink(PathUtils.coverPath + date, (unlinkErr) => {
            if (unlinkErr) {
              if (unlinkErr.code == 13900002) {
                resolve()
              } else {
                reject(new Error(`删除封面失败: ${unlinkErr.message}`))
              }
            } else {
              resolve()
            }
          })
        } else {
          resolve() // 文件不存在也算删除成功
        }
      })
    })
  }

  static async getDownloadFilesUri(): Promise<string[]> {
    const VIDEO_EXTENSIONS = new Set([
      ...SUPPORT_VIDEO_FORMAT,
      ...SUPPORT_AUDIO_FORMAT
    ].map(ext => ext.toLowerCase()))

    class ConcurrencyPool {
      private active = 0
      private pending: Array<() => void> = []
      private concurrency: number

      constructor(concurrency: number) {
        this.concurrency = concurrency
      }

      async run<T>(task: () => Promise<T>): Promise<T> {
        // 如果当前活跃任务数达到并发上限，等待
        if (this.active >= this.concurrency) {
          await new Promise<void>(resolve => {
            this.pending.push(resolve)
          })
        }
        this.active++
        try {
          return await task()
        } finally {
          this.active--
          // 唤醒下一个等待的任务
          this.pending.shift()?.()
        }
      }

      async drain() {
        // 等待所有活跃任务完成
        while (this.active > 0 || this.pending.length > 0) {
          await new Promise<void>((resolve) => setTimeout(resolve, 10))
        }
      }
    }

    // 更高效的扩展名提取函数
    const isVideoFile = (filePath: string): boolean => {
      const lastDotIndex = filePath.lastIndexOf('.')
      if (lastDotIndex === -1) {
        return false
      }
      const ext = filePath.slice(lastDotIndex + 1).toLowerCase()
      return VIDEO_EXTENSIONS.has(ext)
    }
    const dirPool = new ConcurrencyPool(48) // 目录遍历并发控制
    const filePaths: string[] = []
    const processedPaths = new Set<string>() // 避免重复处理

    const collectFiles = async (directory: string): Promise<void> => {
      if (processedPaths.has(directory)) {
        return
      }
      processedPaths.add(directory)
      try {
        const entries: string[] = await fs.listFile(directory)
        // 批量处理条目，提高效率
        const batchSize = 50
        for (let i = 0; i < entries.length; i += batchSize) {
          const batch = entries.slice(i, i + batchSize)
          const batchPromises = batch.map(async (entry: string) => {
            const fullPath: string = `${directory}/${entry}`.replace(/\/+/g, '/') // 规范化路径
            try {
              const stat = await fs.stat(fullPath)
              if (stat.isFile()) {
                // 同步判断文件类型，避免不必要的异步开销
                if (isVideoFile(fullPath)) {
                  filePaths.push(fullPath)
                }
              } else if (stat.isDirectory()) {
                // 目录遍历使用线程池控制并发
                await dirPool.run(() => collectFiles(fullPath))
              }
            } catch (error) {
              salmonLogger.addLog(TAG, `Failed to process ${fullPath}: ${error}`, true)
            }
          })
          // 等待当前批次完成，避免内存溢出
          await Promise.allSettled(batchPromises)
        }
      } catch (error) {
        salmonLogger.addLog(TAG, `Failed to list directory ${directory}: ${error}`, true)
      }
    }
    try {
      await collectFiles(SelectFileUtil.fileFolderUri)
      await dirPool.drain() // 等待所有目录遍历任务完成
      // 去重并返回结果
      return Array.from(new Set(filePaths))
    } catch (error) {
      salmonLogger.addLog(TAG, `Root directory processing failed: ${error}`, true)
      return []
    }
  }

  private static async selectFromAlbum(mimeType: photoAccessHelper.PhotoViewMIMETypes,
    maxSelect: number = Number.MAX_SAFE_INTEGER): Promise<string[]> {
    const options = new photoAccessHelper.PhotoSelectOptions()
    options.MIMEType = mimeType
    options.maxSelectNumber = maxSelect
    options.isPhotoTakingSupported = false
    try {
      const picker = new photoAccessHelper.PhotoViewPicker()
      const result: photoAccessHelper.PhotoSelectResult = await picker.select(options)
      return result.photoUris || []
    } catch (error) {
      salmonLogger.addLog(TAG, `Error selecting media [${mimeType}]:${error}`, true)
      return []
    }
  }
}
