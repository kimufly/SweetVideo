import { FileFolder } from '../../interfaces/FileFolderInterface'
import { FileFolderDataSource, VideoDataSource } from '../../utils/DataUtil'
import { SideBarController } from '../SideBarComponent/SideBar'
import { VideoListController } from '../VideoItemComponent/VideoItemComponent'
import { SymbolGlyphModifier } from '@kit.ArkUI'
import DataSyncUtil from '../../utils/DataSyncUtil'
import { PathUtils } from '../../utils/PathUtils'
import FileFolderUtil from '../../utils/FileFolderUtil'
import ToolsUtil from '../../utils/ToolsUtil'
import { EditFileFolderNameDialog } from '../../component/Dialog/EditFileFolderNameDialog'
import { FileFolderListBuilder } from './FileFolderListComponent'
import { DeleteType } from '../../common/enum/DeleteType'
import { DefaultDialogShadow, MenuFancyModifier } from '../../common/AttributeModifierConfig'
import { InfoConfirmDialog } from '../../component/Dialog/InfoConfirmDialog'

@ComponentV2
export struct FileFolderView {
  @Consumer() fileFolderSource: FileFolderDataSource = new FileFolderDataSource([])
  editFileFolderNameDialogController: CustomDialogController = new CustomDialogController({
    builder: EditFileFolderNameDialog({
      confirm: async (file_folder: string | undefined) => {
        if (!file_folder || file_folder.trim() == '') {
          return
        }
        await FileFolderUtil.changeFileFolderName(PathUtils.appContext!,
          DataSyncUtil.editingFolder!,
          file_folder, this.fileFolderSource)
      }
    }), cornerRadius: 20, shadow: DefaultDialogShadow
  })
  @Local fileFolderList: FileFolder[] = this.fileFolderSource.getAllData()
  @Consumer() videoListController: VideoListController = new VideoListController()
  @Consumer() sideBarController: SideBarController = new SideBarController()
  @Local folderDeleteConfirmText: ResourceStr = ''
  delConfirmDialog: CustomDialogController = new CustomDialogController({
    builder: InfoConfirmDialog({
      textInfo: this.folderDeleteConfirmText,
      confirm: async () => {
        const folderToDelete = DataSyncUtil.editingFolder
        if (!folderToDelete) {
          return
        }
        const videosToDelete = Array.from(folderToDelete.video_list)
        const deletePromises = videosToDelete.map(async item => {
          await this.videoListController.videoDataSource.deleteItem(DeleteType.SOFT, item)
        })
        await Promise.all(deletePromises)
        this.fileFolderSource.deleteData(this.fileFolderList.findIndex(i => i.date === folderToDelete.date))
        this.fileFolderList = FileFolderUtil.deleteFileFolder(PathUtils.appContext!, folderToDelete)
        await this.videoListController.refreshFolderData()
      }
    }), cornerRadius: 20, shadow: DefaultDialogShadow
  })

  build() {
    List() {
      LazyForEach(this.fileFolderSource, (item: FileFolder) => {
        ListItem() {
          FileFolderListBuilder({
            folder: item,
            videoListController: this.videoListController
          })
        }
        .onClick(() => {
          // 优先检查缓存
          const cached = this.videoListController.getCachedFolder(item.date)
          if (cached && cached.video_list.length > 0) {
            this.videoListController.updateData(undefined, cached)
            this.sideBarController.close(true)
            return
          }

          // 缓存未命中：保持当前列表，延迟加载避免阻塞侧边栏关闭动画
          this.videoListController.startFolderSwitch({ name: item.name, date: item.date, video_list: [] })
          this.sideBarController.close(true)

          if (item.name) {
            const targetDate = item.date
            setTimeout(() => {
              FileFolderUtil.loadFolderVideosAsync(PathUtils.appContext!, item.name)
                .then(videos => {
                  // 竞态保护：加载完成时若用户已切换到其他文件夹，则不更新数据
                  if (this.videoListController.folder?.date !== targetDate) {
                    console.info(`[FileFolderView] Folder changed during load, skip updating ${item.name}`)
                    return
                  }
                  const folderWithVideos: FileFolder = { name: item.name, date: item.date, video_list: videos }
                  this.videoListController.updateData(new VideoDataSource(videos), folderWithVideos)
                })
                .catch(e => {
                  console.error(`[FileFolderView] Failed to load videos for ${item.name}: ${e}`)
                })
            }, 0)
          }
        })
        .bindContextMenu(this.FileFolderSelectMenu(item), ResponseType.LongPress)
        .bindContextMenu(this.FileFolderSelectMenu(item), ResponseType.RightClick)
        .height(60)
      }, (item: FileFolder) => item.date)
    }
    .borderRadius(16)
    .width('100%')
    .height('auto')
    .align(Alignment.Start)
    .margin({ top: 10 })
    .backgroundColor($r('app.color.start_window_background_blur'))
    .cachedCount(2)
  }

  @Builder
  FileFolderSelectMenu(file_folder: FileFolder) {
    Menu() {
      MenuItem({
        symbolStartIcon: new SymbolGlyphModifier($r("sys.symbol.trash_fill")),
        content: $r('app.string.delete')
      })
        .onClick(() => {
          DataSyncUtil.editingFolder = file_folder
          this.folderDeleteConfirmText = `确定要删除文件夹 "${file_folder.name}" 吗？\n其中包含 ${file_folder.video_list.length} 个视频。`
          this.delConfirmDialog.open()
        })
      MenuItem({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.rename')),
        content: $r('app.string.edit')
      }).onClick(() => {
        DataSyncUtil.editingFolder = file_folder
        this.editFileFolderNameDialogController.open()
      })
    }.attributeModifier(new MenuFancyModifier).onAppear(() => {
      ToolsUtil.startVibration()
    })
  }
}