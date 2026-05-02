import NavigationAddress, { PlayerParams } from '../../common/NavigationCommon'
import { MpvController } from '../../controller/MpvController/MpvController'
import { PlayerControllerFactory } from '../../controller/PlayerControllerFactory'
import { VideoMetadata } from '../../interfaces/VideoMetadataInterface'
import { Privacy, Setting } from '../../utils/ObservedUtil'
import { PathUtils } from '../../utils/PathUtils'
import VideoOperateUtil from '../../utils/VideoOperateUtil'
import { WindowUtil } from '../../utils/WindowUtil'
import PermissionUtil from '../../utils/PermissionUtil'
import { XAnimation } from '../../utils/AnimationUtil'
import { FastForwardPanelBuilder } from '../../component/PlayerComponent/FastForwardPanelBuilder'
import { SwipingPlayTimePanelBuilder } from '../../component/PlayerComponent/SwipingPlayTimePanelBuilder'
import { VolumeSwipingPanelBuilder } from '../../component/PlayerComponent/VolumeSwipingPanelBuilder'
import { BrightnessSwipingBuilder } from '../../component/PlayerComponent/BrightnessSwipingBuilder'
import { LockVideoBarComponent } from '../../component/PlayerComponent/LockVideoBarComponent'
import { GestureComponent } from '../../component/PlayerComponent/GestureComponent'
import VideoInfoUtil from '../../utils/VideoInfoUtil'
import ToolsUtil from '../../utils/ToolsUtil'
import { window } from '@kit.ArkUI'
import { Subtitle3DMode } from '../../common/enum/SubtitleMode'
import { XComponents } from '../../component/PlayerComponent/XComponents'
import { VideoLayoutComponent } from '../../component/PlayerComponent/VideoLayoutComponent'
import {
  DEFAULT_ANGLE,
  MIRRORED_ANGLE,
  NO_BLUR_AMOUNT,
  PRIVACY_BACKGROUND_BLUR_AMOUNT
} from '../../common/Constants'
import { AISubtitleComponent } from '../../component/PlayerComponent/AIAsrComponent'
import { PlayerSideBarComponent } from '../../component/PlayerComponent/PlayerSideBarComponent'
import PiPWindowUtil from '../../utils/PiPWindowUtil'
import { DefaultDialogShadow } from '../../common/AttributeModifierConfig'
import { NumberInputDialog } from '../../component/Dialog/NumberInputDialog'
import { salmonLogger } from 'salmonlogger'
import { SweetRepeatMode } from '../../common/enum/SweetRepeatMode'
import { AudioTrackComponent } from '../../component/PlayerComponent/AudioTrackComponent'
import { AVCastPickerBuilder } from '../../component/PlayerComponent/AVCastPickerBuilder'
import { PlaybackSpeedMenuComponent } from '../../component/PlayerComponent/PlaybackSpeedComponent'
import { SubtitlePanelComponent } from '../../component/PlayerComponent/SubtitlePanelComponent'
import { VideoButtonsComponent } from '../../component/PlayerComponent/VideoButtonsComponent'
import { VideoSettingComponent } from '../../component/PlayerComponent/VideoSettingComponent'
import { VideoSliderComponent } from '../../component/PlayerComponent/VideoSliderComponent'
import { VideoTopComponent } from '../../component/PlayerComponent/VideoTopComponent'

const TAG = 'MpvPlayer'

@ComponentV2
export struct MpvPlayer {
  xComponentController: XComponentController = new XComponentController()
  osdXController: XComponentController = new XComponentController()
  @Local subtitleVisibility: Visibility = Visibility.Visible
  @Local lockRotation: boolean = false
  @Consumer('pathStack') pathStack: NavPathStack = new NavPathStack()
  @Provider('player') mpv: MpvController = PlayerControllerFactory.createMpvController()
  personalScreenExtendDialog: CustomDialogController = new CustomDialogController({
    builder: NumberInputDialog({
      title: '自定义屏幕拓展比例',
      placeholderColor: '输入范围：50-150',
      confirm: (input: number) => {
        if (input && input <= 150 && input >= 50) {
          this.mpv.playAreaHeight = input / 100 * VideoInfoUtil.playAreaHeight
          this.mpv.playAreaWidth = input / 100 * VideoInfoUtil.playAreaWidth
        } else {
          ToolsUtil.showToast('输入错误')
        }
      },
    }), cornerRadius: 20, shadow: DefaultDialogShadow
  })
  @Local isAIAsrShown: boolean = false
  @Local sideBarStatus: boolean = false
  @Local sideBarStatusTmp: Visibility = Visibility.Hidden
  @Local subtitle3DMode: Subtitle3DMode = Subtitle3DMode.DISABLED
  @Local exitVideoTime: number = 0

  async aboutToAppear(): Promise<void> {
    await this.mpv.onAppear()
  }

  aboutToDisappear(): void {
    this.mpv.onDisappear()
    clearTimeout(this.exitVideoTime)
  }

  build() {
    NavDestination() {
      SideBarContainer(SideBarContainerType.Overlay) {
        PlayerSideBarComponent({
          sideBarStatusTmp: this.sideBarStatusTmp,
          onSideBarStatusTmpChange: (v: Visibility) => {
            this.sideBarStatusTmp = v
          },
          sideBarStatus: this.sideBarStatus,
          onSideBarStatusChange: (v: boolean) => {
            this.sideBarStatus = v
          },
          onItemClick: async (item: VideoMetadata) => {
            await this.mpv.playChooseVideo(item, this.pathStack)
            this.closeSideBar(true)
          }
        })
        Stack() {
          XComponents({
            xComponentController: this.xComponentController,
            xComponentId: 'xcomponentId',
            libraryName: 'mpvnative',
            choosePlayer: NavigationAddress.MPV_PLAYER,
            barState: this.mpv.showControl,
            subtitle3DMode: this.subtitle3DMode,
            subtitleVisibility: this.subtitleVisibility,
            osdXController: this.osdXController,
            osdVisibility: this.mpv.osdVisibility,
            onXComponentLoad: async () => {
              await PermissionUtil.activatePermission(this.mpv.nowPlaying?.uri)
              try {
                this.mpv.init(this.mpv.nowPlaying!.uri, this.pathStack)
                await this.mpv.initAVSession()
                PiPWindowUtil.createPipController(this.xComponentController, this.mpv)
                this.mpv.surfaceId = this.xComponentController.getXComponentSurfaceId()
              } catch (error) {
                salmonLogger.addLog(TAG, 'uri error:' + error, true)
              }
            },
            onKeyCodeEscape: () => {
              VideoOperateUtil.fullScreenOrRotateScreen(this.mpv.screenWidth, this.mpv.screenHeight,
                this.mpv.windowClass)
            },
            onKeyCodeLeft: () => {
              this.mpv.backForward()
            },
            onKeyCodeRight: () => {
              this.mpv.fastForward()
            },
            onKeyCodeSpace: () => {
              this.mpv.togglePlayback()
            },
            onKeyCodeUpAndDown: (event: KeyEvent) => {
              this.mpv.onVolumeKeyEvent(event)
            },
            onOsdSurfaceLoad: (surfaceId: string) => {
              this.mpv.osdSurfaceId = surfaceId
              this.mpv.syncOsdSurfaceSize()
            },
          })

          if (this.mpv.showControl && !this.mpv.isLock) {
            VideoLayoutComponent({
              VideoTop: () => {
                this.VideoTop()
              },
              VideoButtons: () => {
                this.VideoButtons()
              },
              VideoSlider: () => {
                this.VideoSlider()
              },
            })
          }

          if (this.mpv.longPress) {
            FastForwardPanelBuilder({
              speed: this.mpv.speed,
              location: VideoInfoUtil.playAreaHeight,
            })
          }

          if (this.mpv.onSwiping) {
            SwipingPlayTimePanelBuilder({
              isSliderPlayTimeChange: this.mpv.isSliderPlayTimeChange,
              playTime: this.mpv.playTime,
              totalTime: this.mpv.nowPlaying!.time,
              pixelMap: null,
              player: NavigationAddress.MPV_PLAYER
            })
          }
          VolumeSwipingPanelBuilder({
            videoVolume: this.mpv.volume,
            videoVolumeShow: this.mpv.volumeActually,
            onSwipingVoice: this.mpv.onSwipingVoice,
            playAreaHeight: VideoInfoUtil.playAreaHeight,
          })
          if (this.mpv.onSwipingBrightness) {
            BrightnessSwipingBuilder({
              screenBrightness: this.mpv.screenBrightness,
              playAreaHeight: VideoInfoUtil.playAreaHeight
            })
          }
          if (this.mpv.lockVisibility) {
            LockVideoBarComponent({
              onLockClick: () => {
                this.mpv.isLock = !this.mpv.isLock
                this.mpv.showControl = true
              }
            })
          }
          GestureComponent({
            onDoubleClickAction: (tapX: number) => {
              this.mpv.onScreenDoubleClick(tapX)
            },
            onSingleClickAction: () => {
              if (this.sideBarStatus) {
                this.closeSideBar(true)
              } else {
                this.mpv.lockVisibility = !this.mpv.lockVisibility
                XAnimation.runWithAnimation(() => {
                  if (this.mpv.isLock) {
                    this.mpv.showControl = false
                  } else {
                    this.mpv.showControl = !this.mpv.showControl
                  }
                })
              }
            },
            onVerticalPanStart: (tapX: number) => {
              this.mpv.onVerticalPanStart(tapX)
            },
            onVerticalPanUpdate: (offsetY: number) => {
              this.mpv.onVerticalPanUpdate(offsetY)
            },
            onVerticalPanEnd: () => {
              this.mpv.onVerticalPanEnd()
            },
            onHorizonPanStart: () => {
              this.mpv.onHorizonPanStart()
            },
            onHorizonPanUpdate: (offsetX: number) => {
              this.mpv.onHorizonPanUpdate(offsetX)
            },
            onHorizonPanEnd: () => {
              this.mpv.onHorizonPanEnd()
            },
            onPinchStart: (fingerDistance: number) => {
              this.mpv.onPinchStart(fingerDistance)
            },
            onPinchUpdate: (fingerDistance: number) => {
              this.mpv.onPinchUpdate(fingerDistance)
            },
            onPinchEnd: () => {
              this.mpv.onPinchEnd()
            },
            onLongPressAction: () => {
              this.mpv.onLongPressAction()
            },
            onLongPressEnd: () => {
              this.mpv.onLongPressEnd()
            },
            onLongPressPanStart: (tapX: number) => {
              this.mpv.onLongPressPanStart(tapX)
            },
            onLongPressPanUpdate: (tapX: number) => {
              this.mpv.onLongPressPanUpdate(tapX)
            },
            onPanMoveStart: (event: GestureEvent) => {
              this.mpv.onPanMoveStart(event)
            },
            onPanMoveUpdate: (event: GestureEvent) => {
              this.mpv.onPanMoveUpdate(event)
            }
          })
            .hitTestBehavior(HitTestMode.Transparent)

          AISubtitleComponent({
            isAIAsrShown: this.isAIAsrShown,
            showControl: this.mpv.showControl,
            screenHeight: this.mpv.screenHeight,
          })
        }.onAreaChange(async (_oldValue: Area, newValue: Area) => {
          this.mpv.handleAreaChange(newValue)
        })
        .height('100%')
        .width('100%')
        .backgroundColor($r('sys.color.black'))
      }
      .showControlButton(false)
      .onChange((value: boolean) => {
        this.sideBarStatus = value
      })
      .sideBarWidth(300)
      .showSideBar(this.sideBarStatus)
      .sideBarPosition(SideBarPosition.End)
      .divider({ strokeWidth: 0 })
    }
    .onShown(() => {
      if (PiPWindowUtil.pipOpenState) {
        PiPWindowUtil.stopPip()
      }
    })
    .onReady(() => {
      const playerParams: PlayerParams =
        this.pathStack.getParamByName(NavigationAddress.MPV_PLAYER)[0] as PlayerParams
      try {
        this.mpv.nowPlaying = playerParams.metadata as VideoMetadata
        this.mpv.videoMetaDataList = playerParams.metadata_list as VideoMetadata[]
      } catch (e) {
        salmonLogger.addLog(TAG, String(e), true)
      }
    })
    .onWillDisappear(async () => {
      this.exitVideo(false)
      await this.mpv.onWillDisappear()
    })
    .onBackPressed(() => {
      if (this.sideBarStatus) {
        this.closeSideBar(true)
        return true
      }
      if (this.mpv.showControl && !Setting.allowPlayBackExist) {
        this.mpv.showControl = false
        this.mpv.lockVisibility = false
        return true
      } else {
        return false
      }
    })
    .hideTitleBar(true)
    .blur(Privacy.isPrivacyBackground ? PRIVACY_BACKGROUND_BLUR_AMOUNT : NO_BLUR_AMOUNT)
  }

  closeSideBar(isPlayAnimation: boolean) {
    this.sideBarStatusTmp = Visibility.Hidden
    isPlayAnimation ? setTimeout(() => {
      this.sideBarStatus = false
    }, 400) : this.sideBarStatus = false
  }

  @Builder
  VideoTop() {
    VideoTopComponent({
      subTitleVisibility: this.subtitleVisibility,
      audioTrackMenuBuilder: () => {
        this.AudioTrackMenuBuilder()
      },
      subtitlePanelComponent: () => {
        this.SubtitleMenuBuilder()
      },
      lockRotation: this.lockRotation,
      onExitVideoClick: () => {
        this.exitVideo(true)
        ToolsUtil.addLogger("点击退出视频按钮", false, this.pathStack)
      },
      onLockRotationClick: async () => {
        this.lockRotation = !this.lockRotation
        ToolsUtil.addLogger(`锁定旋转状态切换为：${this.lockRotation}`, false, this.pathStack)
        const orientation = this.lockRotation ?
          (this.mpv.screenWidth > this.mpv.screenHeight ? window.Orientation.AUTO_ROTATION_LANDSCAPE_RESTRICTED
            : window.Orientation.AUTO_ROTATION_PORTRAIT_RESTRICTED)
          : window.Orientation.AUTO_ROTATION_RESTRICTED
        try {
          XAnimation.runWithAnimation(async () => {
            await (await this.mpv.windowClass)?.setPreferredOrientation(orientation)
            ToolsUtil.addLogger("窗口方向设置成功", false, this.pathStack)
          })
        } catch (error) {
          ToolsUtil.addLogger(`屏幕旋转异常: ${error.code}:${error.message}`, true, this.pathStack)
        }
        const toastMessage = this.lockRotation
          ? ToolsUtil.getStringResource($r('app.string.open_rotation_lock').id)
          : ToolsUtil.getStringResource($r('app.string.close_rotation_lock').id)
        ToolsUtil.showToast(toastMessage)
        ToolsUtil.addLogger(`显示旋转锁定提示：${toastMessage}`, false, this.pathStack)
      },
      onSpecificVideoProportions: (playAreaSize: number[]) => {
        this.mpv.onSpecificVideoProportions(playAreaSize)
      },
      onOriginalRatio: () => {
        this.mpv.onOriginalRatio()
      },
      onStretchedToFullScreen: () => {
        this.mpv.onStretchedToFullScreen()
      },
      onFullScreenByWidth: () => {
        this.mpv.onFullScreenByWidth()
      },
      onFullScreenByHeight: () => {
        this.mpv.onFullScreenByHeight()
      },
      onUniformScale: (scale: number) => {
        this.mpv.onUniformScale(scale)
      },
      onSelectedTextChange: (text: string) => {
        this.mpv.selectedText = text
      },
      pipStateChange: () => {
        PiPWindowUtil.startPip()
        WindowUtil.minimizeClick(PathUtils.appContext!)
      },
      onOpenPersonalScreenExtend: () => {
        this.personalScreenExtendDialog.open()
      }
    })
  }

  exitVideo(shouldPop: boolean = true) {
    this.mpv.release()
    if (shouldPop) {
      this.pathStack.pop()
    }
  }

  @Builder
  VideoButtons() {
    VideoButtonsComponent({
      AVCastPickerBuilderBridge: this.AVCastPickerBuilderBridge,
      videoSettingBuilder: () => {
        this.VideoSettingBuilder()
      },
      playbackSpeedMenu: () => {
        this.PlaybackSpeedMenuBuilder()
      },
      sideBarStatusTmp: this.sideBarStatusTmp,
      onSideBarStatusTmpChange: (v: Visibility) => {
        this.sideBarStatusTmp = v
      },
      sideBarStatus: this.sideBarStatus,
      onSideBarStatusChange: (v: boolean) => {
        this.sideBarStatus = v
      },
      onScreenRotationOrFullScreenClick: async () => {
        VideoOperateUtil.fullScreenOrRotateScreen(this.mpv.screenWidth, this.mpv.screenHeight, this.mpv.windowClass)
      },
      onTogglePlaybackClick: () => {
        this.mpv.togglePlayback()
      },
      onPlayNextVideoClick: () => {
        this.mpv.playNextVideoProcess(this.pathStack)
        ToolsUtil.addLogger("播放下一个视频请求已发送", false, this.pathStack)
      },
      onSideBaClose: () => {
        this.closeSideBar(true)
      },
      onChangeRepeatMode: (repeatMode: SweetRepeatMode) => {
        this.mpv.repeatMode = repeatMode
      }
    })
  }

  @Builder
  VideoSettingBuilder() {
    VideoSettingComponent({
      exitVideoTime: this.exitVideoTime,
      forward_80_s: (time: number) => {
        ToolsUtil.addLogger(`执行快进80秒操作，目标时间：${time}`, false, this.pathStack)
        this.mpv.seekTime(time)
      },
      closeAfter15min: (_time: number) => {
        ToolsUtil.showToast('功能暂不可用')

      },
      closeAfter30min: (_time: number) => {
        ToolsUtil.showToast('功能暂不可用')
      },
      closeAfter60min: (_time: number) => {
        ToolsUtil.showToast('功能暂不可用')
      },
      toggleListenVideo: () => {
        ToolsUtil.showToast('功能暂不可用')
      },
      captureScreen: () => {
        salmonLogger.addLog(TAG, 'test' + this.mpv.surfaceId, true)
        if (this.mpv.surfaceId) {
          salmonLogger.addLog(TAG, 'test', true)
          VideoOperateUtil.saveCaptureScreenToAlbum(this.mpv.surfaceId)
        }
      },
      updateStarTime: (time: number) => {
        this.mpv.nowPlaying!.start_time = time
      },
      updateEndTime: (time: number) => {
        this.mpv.nowPlaying!.end_time = time
      },
      updatePointATime: (time: number) => {
        this.mpv.nowPlaying!.pointA = time
      },
      updatePointBTime: (time: number) => {
        this.mpv.nowPlaying!.pointB = time
      },
      onScreenMirror: () => {
        this.mpv.angle === DEFAULT_ANGLE ? this.mpv.angle = MIRRORED_ANGLE : this.mpv.angle = DEFAULT_ANGLE
      },
      setRepeatModeToOnce: () => {
        this.mpv.repeatMode = SweetRepeatMode.ONCE
      },
    })
  }

  @Builder
  VideoSlider() {
    VideoSliderComponent({
      onSliderChange: (value: number) => {
        this.mpv.onSwiping = true
        this.mpv.isSliderPlayTimeChange = true
        this.mpv.playTime = value
      },
      onSliderTouch: (event: TouchEvent) => {
        if (event.type == TouchType.Up) {
          this.mpv.seekTime(this.mpv.playTime)
          this.mpv.isSliderPlayTimeChange = false
          this.mpv.onSwiping = false
        }
      }
    })
  }

  @Builder
  AudioTrackMenuBuilder() {
    AudioTrackComponent({
      onSelect: (index: number) => {
        ToolsUtil.addLogger(`选择音频轨道，索引：${index}`, false, this.pathStack)
        this.mpv?.selectAudioTrack(this.mpv?.audioTrack[index]?.id)
        this.mpv.audioTrackSelected = index
      }
    })
  }

  @Builder
  SubtitleMenuBuilder() {
    SubtitlePanelComponent({
      subtitleVisibility: this.subtitleVisibility,
      isAIAsrShown: this.isAIAsrShown,
      subtitle3DMode: this.subtitle3DMode,
      onSubtitle3DModeChange: (v: Subtitle3DMode) => {
        this.subtitle3DMode = v
      }
    })
  }

  @Builder
  AVCastPickerBuilderBridge() { // 桥接AVCastPickerBuilder避免crash
    AVCastPickerBuilder()
  }

  @Builder
  PlaybackSpeedMenuBuilder() {
    PlaybackSpeedMenuComponent({
      onSpeedChange: (speed: number) => {
        this.mpv.updatePlaybackSpeed(speed)
      }
    })
  }
}

