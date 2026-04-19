import { FileFolder } from '../interfaces/FileFolderInterface'
import { VideoMetadata } from '../interfaces/VideoMetadataInterface'
import { VideoListController } from '../component/VideoItemComponent/VideoItemComponent'
import { SideBarController } from '../component/SideBarComponent/SideBar'
import { FileFolderDataSource, VideoDataSource } from '../utils/DataUtil'
import FileFolderUtil from '../utils/FileFolderUtil'
import { PathUtils } from '../utils/PathUtils'
import SelectFileUtil from '../utils/SelectFileUtil'
import { Setting } from '../utils/ObservedUtil'
import VideoUtils from '../utils/VideoUtil'

/**
 * 文件夹滑动手势处理器
 * 处理侧边栏展开/收起和文件夹间切换的滑动手势
 */
export class FolderGestureHandler {
  private file_folder_list: FileFolder[]
  private videoListController: VideoListController
  private sideBarController: SideBarController
  private fileFolderSource: FileFolderDataSource
  private onFolderSwitch: (folder: FileFolder, index: number) => void
  private onSideBarScroll: (offset: number) => void

  constructor(
    file_folder_list: FileFolder[],
    videoListController: VideoListController,
    sideBarController: SideBarController,
    fileFolderSource: FileFolderDataSource,
    onFolderSwitch: (folder: FileFolder, index: number) => void,
    onSideBarScroll: (offset: number) => void
  ) {
    this.file_folder_list = file_folder_list
    this.videoListController = videoListController
    this.sideBarController = sideBarController
    this.fileFolderSource = fileFolderSource
    this.onFolderSwitch = onFolderSwitch
    this.onSideBarScroll = onSideBarScroll
  }

  /**
   * 更新文件夹列表引用
   */
  updateFolderList(folders: FileFolder[]): void {
    this.file_folder_list = folders
  }

  /**
   * 处理滑动手势
   */
  handleSwipe(event: GestureEvent): void {
    // 批量选择模式下禁止切换
    if (this.videoListController.multipleChooseState === Visibility.Visible) {
      return
    }

    // 侧边栏展开时（Overlay 模式）：左滑关闭侧边栏
    if (this.sideBarController.visibility === Visibility.Visible &&
      this.sideBarController.mode === SideBarContainerType.Overlay) {
      const rotateAngle = event.angle ?? 0
      if (rotateAngle < -135 || rotateAngle > 135) {
        this.sideBarController.close(true)
      }
      return
    }

    const rotateAngle = event.angle ?? 0
    const isSwipeRight = rotateAngle > -45 && rotateAngle < 45
    const isSwipeLeft = rotateAngle < -135 || rotateAngle > 135

    // 面包屑未开启时：只允许右滑打开侧边栏（仅 Overlay 模式）
    if (!Setting.showToast) {
      if (isSwipeRight && this.sideBarController.mode === SideBarContainerType.Overlay) {
        this.sideBarController.open()
      }
      return
    }

    // 文件夹列表为空或只有一个时：右滑打开侧边栏（仅 Overlay 模式）
    if (this.file_folder_list.length <= 1) {
      if (isSwipeRight && this.sideBarController.mode === SideBarContainerType.Overlay) {
        this.sideBarController.open()
      }
      return
    }

    const currentIndex = this.getCurrentFolderIndex()
    if (currentIndex === -1) {
      console.error(`[FolderGestureHandler] current folder not found in list`)
      return
    }

    const isFirstFolder = currentIndex === 0
    const isLastFolder = currentIndex === this.file_folder_list.length - 1

    if (isSwipeRight) {
      if (isFirstFolder) {
        // 第一个文件夹右滑 -> 打开侧边栏（仅 Overlay 模式）
        if (this.sideBarController.mode === SideBarContainerType.Overlay) {
          this.sideBarController.open()
        }
      } else {
        // 切换到上一个文件夹
        void this.switchToFolder(currentIndex - 1)
      }
    } else if (isSwipeLeft) {
      // 从右向左滑
      if (!isLastFolder) {
        void this.switchToFolder(currentIndex + 1)
      }
    }
  }

  /**
   * 获取当前文件夹在列表中的索引
   */
  getCurrentFolderIndex(): number {
    return this.file_folder_list.findIndex(
      folder => folder.date === this.videoListController?.folder?.date
    )
  }

  /**
   * 切换到指定索引的文件夹
   */
  async switchToFolder(index: number): Promise<void> {
    if (index < 0 || index >= this.file_folder_list.length) {
      return
    }

    const targetFolder = this.file_folder_list[index]
    if (this.videoListController.folder?.date === targetFolder.date) {
      return
    }

    await this.performFolderSwitch(targetFolder, index)
  }

  /**
   * 执行文件夹切换
   * 交互优化：先立即切换 UI（空列表 + loading），再异步加载视频，确保手势滑动不被阻塞
   */
  private performFolderSwitch(targetFolder: FileFolder, index: number): void {
    // 优先检查缓存：如果该文件夹已加载过，直接切换，不再查询 ORM
    const cached = this.videoListController.getCachedFolder(targetFolder.date)
    if (cached && cached.video_list.length > 0) {
      this.videoListController.updateData(undefined, cached)
      this.onFolderSwitch(targetFolder, index)
      const estimatedOffset = index > 0 ? 260 + (index - 1) * 70 : 0
      animateToImmediately({ duration: 200, curve: Curve.Ease }, () => {
        this.onSideBarScroll(estimatedOffset)
      })
      return
    }

    // 缓存未命中：保持当前列表显示，只更新 folder 引用和 loading 状态，延迟加载避免阻塞切换动画
    this.videoListController.startFolderSwitch({ name: targetFolder.name, date: targetFolder.date, video_list: [] })

    this.onFolderSwitch(targetFolder, index)
    const estimatedOffset = index > 0 ? 260 + (index - 1) * 70 : 0
    animateToImmediately({ duration: 200, curve: Curve.Ease }, () => {
      this.onSideBarScroll(estimatedOffset)
    })

    // 延迟到下一帧加载，让切换动画先完成
    setTimeout(() => {
      this.loadFolderVideosAsync(targetFolder)
    }, 0)
  }

  private async loadFolderVideosAsync(targetFolder: FileFolder): Promise<void> {
    let videos: VideoMetadata[] = []
    if (targetFolder.name) {
      try {
        videos = await FileFolderUtil.loadFolderVideosAsync(PathUtils.appContext!, targetFolder.name)
      } catch (e) {
        console.error(`[FolderGestureHandler] Failed to load videos for ${targetFolder.name}: ${e}`)
      }
    }

    // 竞态保护：加载完成时若用户已切换到其他文件夹，则不更新数据
    if (this.videoListController.folder?.date !== targetFolder.date) {
      console.info(`[FolderGestureHandler] Folder changed during load, skip updating ${targetFolder.name}`)
      return
    }

    const folderWithVideos: FileFolder = { name: targetFolder.name, date: targetFolder.date, video_list: videos }
    this.videoListController.videoDataSource.updateData(videos)
    this.videoListController.updateData(this.videoListController.videoDataSource, folderWithVideos)
  }

  /**
   * 带搜索过滤的文件夹切换
   * 交互优化：先立即切换 UI，再异步加载视频
   */
  switchToFolderWithSearch(index: number, searchValue: string): void {
    if (index < 0 || index >= this.file_folder_list.length) {
      return
    }

    const targetFolder = this.file_folder_list[index]
    if (this.videoListController.folder?.date === targetFolder.date) {
      return
    }

    // 优先检查缓存
    const cached = this.videoListController.getCachedFolder(targetFolder.date)
    if (cached && cached.video_list.length > 0) {
      const filtered = searchValue.length > 0
        ? SelectFileUtil.getItemFromSearch(cached.video_list, searchValue)
        : cached.video_list
      this.videoListController.updateData(new VideoDataSource(filtered), cached)
      this.onFolderSwitch(targetFolder, index)
      const estimatedOffset = index > 0 ? 260 + (index - 1) * 70 : 0
      animateToImmediately({ duration: 200, curve: Curve.Ease }, () => {
        this.onSideBarScroll(estimatedOffset)
      })
      return
    }

    // 缓存未命中：保持当前列表，延迟加载避免阻塞切换动画
    this.videoListController.startFolderSwitch({ name: targetFolder.name, date: targetFolder.date, video_list: [] })

    this.onFolderSwitch(targetFolder, index)
    const estimatedOffset = index > 0 ? 260 + (index - 1) * 70 : 0
    animateToImmediately({ duration: 200, curve: Curve.Ease }, () => {
      this.onSideBarScroll(estimatedOffset)
    })

    setTimeout(() => {
      this.loadFolderVideosWithSearchAsync(targetFolder, searchValue)
    }, 0)
  }

  private async loadFolderVideosWithSearchAsync(targetFolder: FileFolder, searchValue: string): Promise<void> {
    let videos: VideoMetadata[] = []
    if (targetFolder.name) {
      try {
        videos = await FileFolderUtil.loadFolderVideosAsync(PathUtils.appContext!, targetFolder.name)
      } catch (e) {
        console.error(`[FolderGestureHandler] Failed to load videos for ${targetFolder.name}: ${e}`)
      }
    }

    // 竞态保护
    if (this.videoListController.folder?.date !== targetFolder.date) {
      console.info(`[FolderGestureHandler] Folder changed during load (search), skip updating ${targetFolder.name}`)
      return
    }

    let filteredVideos = videos
    if (searchValue.length > 0) {
      filteredVideos = SelectFileUtil.getItemFromSearch(videos, searchValue)
    }

    const folderWithVideos: FileFolder = { name: targetFolder.name, date: targetFolder.date, video_list: videos }
    this.videoListController.videoDataSource.updateData(filteredVideos)
    this.videoListController.updateData(
      this.videoListController.videoDataSource,
      folderWithVideos
    )
  }
}
