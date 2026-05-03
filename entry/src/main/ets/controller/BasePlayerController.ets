import { PlayerControllerInterface } from './PlayerControllerFactory'
import { VideoMetadata } from '../interfaces/VideoMetadataInterface'
import { SweetRepeatMode } from '../common/enum/SweetRepeatMode'
import { SubtitleMode } from '../common/enum/SubtitleMode'
import VideoOperateUtil from '../utils/VideoOperateUtil'
import VideoInfoUtil from '../utils/VideoInfoUtil'
import SelectFileUtil from '../utils/SelectFileUtil'
import ToolsUtil from '../utils/ToolsUtil'
import { Setting } from '../utils/ObservedUtil'
import { salmonLogger } from 'salmonlogger'
import {
  LEFT_ZONE_DIVISION,
  MAX_SCALE_FACTOR,
  MAX_WIDTH_MULTIPLIER,
  MIN_SCALE_FACTOR,
  MIN_WIDTH_MULTIPLIER,
  PINCH_SCALE_SENSITIVITY,
  RIGHT_ZONE_DIVISION,
  SCREEN_DIVISIONS,
  SCREEN_HALF_DIVIDER,
  SWIPE_THRESHOLD,
  VERTICAL_PAN_SENSITIVITY,
  VOLUME_PAN_MULTIPLIER,
  VOLUME_STEP
} from '../common/Constants'
import { audio } from '@kit.AudioKit'
import { KeyCode } from '@kit.InputKit'

@ObservedV2
export abstract class BasePlayerController implements PlayerControllerInterface {
  // ===== Shared @Trace states =====
  @Trace playTime: number = 0
  @Trace playing: boolean = false
  @Trace nowPlaying: VideoMetadata | undefined = undefined
  @Trace videoMetaDataList: VideoMetadata[] = []
  @Trace speed: number = 1.0
  @Trace volume: number = 0
  @Trace volumeActually: number = 0
  @Trace screenBrightness: number = 0
  @Trace onSwipingVoice: boolean = false
  @Trace screenWidth: number = 0
  @Trace screenHeight: number = 0
  @Trace playAreaHeight: number = 0
  @Trace playAreaWidth: number = 0
  @Trace angle: number = 0
  @Trace repeatMode: SweetRepeatMode = SweetRepeatMode.LIST
  @Trace selectedText: string | undefined = '原始比例'
  @Trace onSwiping: boolean = false
  @Trace onSwipingBrightness: boolean = false
  @Trace isSliderPlayTimeChange: boolean = false
  @Trace audioTrackSelected: number = 0
  @Trace lockVisibility: boolean = false
  @Trace longPress: boolean = false
  @Trace isLock: boolean = false
  @Trace abCircleStatus: boolean = false
  @Trace isZoomed: boolean = false
  @Trace isPinching: boolean = false
  @Trace translateX: number = 0
  @Trace translateY: number = 0
  @Trace showControl: boolean = false
  @Trace subtitle: string = ''
  @Trace subtitleSelected: SubtitleMode = SubtitleMode.INNER_SUBTITLE

  // ===== Shared non-@Trace fields =====
  audioVolumeManager: audio.AudioVolumeManager | null = null
  readonly playerType: 'avplayer' | 'mpv'

  // ===== Shared private state =====
  protected lastPinchDistance: number = 0

  protected constructor(playerType: 'avplayer' | 'mpv') {
    this.playerType = playerType
  }

  // ===== Engine difference hooks (default empty impl) =====
  protected onVideoSizeChanged(): void {
  }

  protected onSeekPreview(_time: number, _isFirstFrame: boolean): void {
  }

  protected onKeepAspectChanged(_enabled: boolean): void {
  }

  // ===== Pinch gesture =====
  onPinchStart(fingerDistance: number): void {
    this.lastPinchDistance = fingerDistance
    this.isPinching = true
    if (!this.isZoomed) {
      this.translateX = 0
      this.translateY = 0
    }
  }

  onPinchUpdate(fingerDistance: number): void {
    const deltaScale = fingerDistance / this.lastPinchDistance
    const adjustedDelta = 1 + (deltaScale - 1) * PINCH_SCALE_SENSITIVITY
    const clampedDelta = Math.min(Math.max(adjustedDelta, MIN_SCALE_FACTOR), MAX_SCALE_FACTOR)

    let newWidth = this.playAreaWidth * clampedDelta
    let newHeight = this.playAreaHeight * clampedDelta

    const originalWidth = VideoInfoUtil.playAreaWidth
    const originalHeight = VideoInfoUtil.playAreaHeight
    const maxWidth = originalWidth * MAX_WIDTH_MULTIPLIER
    const minWidth = originalWidth * MIN_WIDTH_MULTIPLIER

    newWidth = Math.max(minWidth, Math.min(maxWidth, newWidth))
    newHeight = Math.max(minWidth * originalHeight / originalWidth,
      Math.min(maxWidth * originalHeight / originalWidth, newHeight))

    const scaleRatio = newWidth / this.playAreaWidth
    this.translateX *= scaleRatio
    this.translateY *= scaleRatio

    this.playAreaWidth = newWidth
    this.playAreaHeight = newHeight
    this.isZoomed = newWidth > originalWidth || newHeight > originalHeight

    this.lastPinchDistance = fingerDistance
    this.onVideoSizeChanged()
  }

  onPinchEnd(): void {
    this.isPinching = false
    const originalWidth = VideoInfoUtil.playAreaWidth
    const originalHeight = VideoInfoUtil.playAreaHeight

    if (this.playAreaWidth <= originalWidth && this.playAreaHeight <= originalHeight) {
      this.playAreaWidth = originalWidth
      this.playAreaHeight = originalHeight
      this.translateX = 0
      this.translateY = 0
      this.isZoomed = false
    }
    this.onVideoSizeChanged()
  }

  // ===== Horizontal pan (seek) =====
  onHorizonPanStart(): void {
    VideoOperateUtil.lastPlayTime = this.playTime
    this.onSwiping = true
    this.onSeekPreview(this.playTime, true)
  }

  onHorizonPanUpdate(offsetX: number): void {
    const timePerPixel = VideoOperateUtil.getTimePixel(this.screenWidth, this.nowPlaying?.time!)
    this.playTime = Math.max(0,
      Math.min(VideoOperateUtil.lastPlayTime + (offsetX * timePerPixel), this.nowPlaying?.time!))
    this.onSeekPreview(this.playTime, false)
  }

  onHorizonPanEnd(): void {
    this.seekTime(this.playTime)
    this.onSwiping = false
  }

  // ===== Vertical pan (brightness/volume) =====
  onVerticalPanStart(tapX: number): void {
    VideoOperateUtil.leftSideSwipe = tapX < this.screenWidth / SCREEN_HALF_DIVIDER
    VideoOperateUtil.screenBrightnessTmp = this.screenBrightness
    this.volume = this.volumeActually
    VideoOperateUtil.lastVolume = this.volume
  }

  onVerticalPanUpdate(offsetY: number): void {
    const deltaYScale = offsetY / this.screenHeight * VERTICAL_PAN_SENSITIVITY
    if (VideoOperateUtil.leftSideSwipe) {
      this.onSwipingBrightness = true
      this.screenBrightness = VideoOperateUtil.calNewBrightness(deltaYScale)
      VideoOperateUtil.setBrightness(this.screenBrightness)
    } else {
      this.onSwipingVoice = true
      const newVolume = VideoOperateUtil.lastVolume - deltaYScale * VOLUME_PAN_MULTIPLIER
      this.volume = Math.min(Math.max(newVolume, VideoOperateUtil.minVolume), VideoOperateUtil.maxVolume)
    }
  }

  onVerticalPanEnd(): void {
    this.onSwiping = false
    this.onSwipingVoice = false
    this.onSwipingBrightness = false
  }

  // ===== Long press (speed up) =====
  onLongPressAction(): void {
    if (this.playing) {
      VideoOperateUtil.lastSpeed = this.speed
      this.updatePlaybackSpeed(Setting.longPressSpeed)
      this.longPress = true
    }
  }

  onLongPressEnd(): void {
    this.longPress = false
    this.updatePlaybackSpeed(VideoOperateUtil.lastSpeed)
  }

  onLongPressPanStart(tapX: number): void {
    VideoOperateUtil.longPressStartX = tapX
  }

  onLongPressPanUpdate(tapX: number): void {
    if (!this.longPress) {
      return
    }
    const deltaX = tapX - VideoOperateUtil.longPressStartX
    if (Math.abs(deltaX) <= SWIPE_THRESHOLD) {
      return
    }
    const direction = Math.sign(deltaX)
    const currentSpeedIndex = VideoInfoUtil.videoSpeedListAll.indexOf(this.speed)
    const newIndex = currentSpeedIndex + direction
    const clampedIndex = Math.max(0, Math.min(newIndex, VideoInfoUtil.videoSpeedListAll.length - 1))
    if (clampedIndex === currentSpeedIndex) {
      return
    }
    this.updatePlaybackSpeed(VideoInfoUtil.videoSpeedListAll[clampedIndex])
    VideoOperateUtil.longPressStartX = tapX
  }

  // ===== Pan move (when zoomed) =====
  onPanMoveStart(event: GestureEvent): void {
    VideoOperateUtil.panStartX = event.fingerList[0]?.localX || 0
    VideoOperateUtil.panStartY = event.fingerList[0]?.localY || 0
  }

  onPanMoveUpdate(event: GestureEvent): void {
    const currentX = event.fingerList[0]?.localX || 0
    const currentY = event.fingerList[0]?.localY || 0
    const deltaX = currentX - VideoOperateUtil.panStartX
    const deltaY = currentY - VideoOperateUtil.panStartY
    this.translateX += deltaX
    this.translateY += deltaY
    this.constrainTranslation()
    VideoOperateUtil.panStartX = currentX
    VideoOperateUtil.panStartY = currentY
  }

  constrainTranslation(): void {
    if (!this.isZoomed) {
      this.translateX = 0
      this.translateY = 0
      return
    }
    const maxOffsetX = Math.max(0, (this.playAreaWidth - this.screenWidth) / 2)
    const maxOffsetY = Math.max(0, (this.playAreaHeight - this.screenHeight) / 2)
    this.translateX = Math.max(-maxOffsetX, Math.min(maxOffsetX, this.translateX))
    this.translateY = Math.max(-maxOffsetY, Math.min(maxOffsetY, this.translateY))
  }

  // ===== Screen proportion adjustments =====
  onSpecificVideoProportions(playAreaSize: number[]): void {
    this.playAreaWidth = playAreaSize[0]
    this.playAreaHeight = playAreaSize[1]
    this.isZoomed = false
    this.translateX = 0
    this.translateY = 0
    this.onVideoSizeChanged()
  }

  onOriginalRatio(): void {
    this.onKeepAspectChanged(true)
    this.playAreaHeight = VideoInfoUtil.playAreaHeight
    this.playAreaWidth = VideoInfoUtil.playAreaWidth
    this.isZoomed = false
    this.translateX = 0
    this.translateY = 0
    this.onVideoSizeChanged()
  }

  onStretchedToFullScreen(): void {
    this.onKeepAspectChanged(false)
    this.playAreaHeight = this.screenHeight
    this.playAreaWidth = this.screenWidth
    this.isZoomed = false
    this.translateX = 0
    this.translateY = 0
    this.onVideoSizeChanged()
  }

  onFullScreenByWidth(): void {
    this.playAreaWidth = this.screenWidth
    this.playAreaHeight = (VideoInfoUtil.playAreaHeight / VideoInfoUtil.playAreaWidth) * this.screenWidth
    this.isZoomed = false
    this.translateX = 0
    this.translateY = 0
    this.onVideoSizeChanged()
  }

  onFullScreenByHeight(): void {
    this.playAreaHeight = this.screenHeight
    this.playAreaWidth = (VideoInfoUtil.playAreaWidth / VideoInfoUtil.playAreaHeight) * this.screenHeight
    this.isZoomed = false
    this.translateX = 0
    this.translateY = 0
    this.onVideoSizeChanged()
  }

  onUniformScale(scale: number): void {
    this.playAreaHeight = scale * VideoInfoUtil.playAreaHeight
    this.playAreaWidth = scale * VideoInfoUtil.playAreaWidth
    this.isZoomed = false
    this.translateX = 0
    this.translateY = 0
    this.onVideoSizeChanged()
  }

  // ===== Other shared methods =====
  onScreenDoubleClick(tapX: number): void {
    if (!Setting.allowDoubleFastForward) {
      this.togglePlayback()
      return
    }
    const zoneWidth = this.screenWidth / SCREEN_DIVISIONS
    if (tapX < zoneWidth * LEFT_ZONE_DIVISION) {
      this.backForward()
      return
    }
    if (tapX > zoneWidth * RIGHT_ZONE_DIVISION) {
      this.fastForward()
      return
    }
    this.togglePlayback()
  }

  playNextVideo(repeatMode: SweetRepeatMode): VideoMetadata | undefined {
    if (this.videoMetaDataList.length === 0) {
      return undefined
    }
    let item = SelectFileUtil.getItem(this.videoMetaDataList, this.nowPlaying?.date || '') as VideoMetadata
    if (!item) {
      item = this.videoMetaDataList[0]
    }
    switch (repeatMode) {
      case SweetRepeatMode.RANDOM:
        const availableVideos = this.videoMetaDataList.filter(v => v.date !== item.date)
        return availableVideos.length > 0
          ? availableVideos[Math.floor(Math.random() * availableVideos.length)]
          : item
      case SweetRepeatMode.ONCE:
        return undefined
      case SweetRepeatMode.SEQUENCE:
        if (SelectFileUtil.isLastItem(this.videoMetaDataList, item.date)) {
          return undefined
        }
        return SelectFileUtil.getNextItem(this.videoMetaDataList, item.date)
      case SweetRepeatMode.SINGLE:
        return this.videoMetaDataList.find(v => v.date === this.nowPlaying?.date)!
      case SweetRepeatMode.LIST:
        return SelectFileUtil.getNextItem(this.videoMetaDataList, item.date)
      default:
        return undefined
    }
  }

  togglePlayback(): void {
    this.playing ? this.pause() : this.play()
  }

  backForward(): void {
    this.seekTime(this.playTime - Number(Setting.fastForwardSeconds) * 1000)
  }

  fastForward(): void {
    this.seekTime(this.playTime + Number(Setting.fastForwardSeconds) * 1000)
  }

  onVolumeKeyEvent(event: KeyEvent): void {
    this.volume = this.volumeActually
    const newVolume = VideoOperateUtil.changeVolume(this.volume,
      event.keyCode === KeyCode.KEYCODE_DPAD_UP ? VOLUME_STEP : -VOLUME_STEP)
    this.volume = newVolume
    this.volumeActually = newVolume
    VideoOperateUtil.lastVolume = newVolume
  }

  handleAreaChange(newValue: Area): void {
    this.screenWidth = Math.floor(new Number(newValue.width).valueOf())
    this.screenHeight = Math.floor(new Number(newValue.height).valueOf())
    this.setRotation()
  }

  async initVolumeAndBrightness() {
    let groupId: number = audio.DEFAULT_VOLUME_GROUP_ID
    let audioManager = audio.getAudioManager()
    this.audioVolumeManager = audioManager.getVolumeManager()
    let volumeList = await VideoOperateUtil.getVolume(this.audioVolumeManager, groupId)
    this.volume = volumeList.get('volume')!
    this.volumeActually = this.volume
    let swipingVoiceTimer: number | null = null
    let changeVolumeByVolumeButton: boolean = false
    try {
      this.audioVolumeManager.on('streamVolumeChange', audio.StreamUsage.STREAM_USAGE_MOVIE,
        (streamVolumeEvent: audio.StreamVolumeEvent) => {
          clearTimeout(swipingVoiceTimer)
          if (!this.onSwipingVoice) {
            this.onSwipingVoice = !this.onSwipingVoice
            changeVolumeByVolumeButton = true
          }
          this.volumeActually = streamVolumeEvent.volume
          ToolsUtil.startVibration()
          swipingVoiceTimer = setTimeout(() => {
            if (changeVolumeByVolumeButton) {
              this.onSwipingVoice = !this.onSwipingVoice
              changeVolumeByVolumeButton = false
            }
          }, 800)
        })
    } catch (error) {
      salmonLogger.addLog('BasePlayerController', 'volumeChange error:' + error, true)
    }
    this.screenBrightness = await VideoOperateUtil.getScreenBrightness()
  }

  // ===== Abstract methods (subclasses must implement) =====
  abstract seekTime(seekTime: number): void
  abstract play(): void
  abstract pause(): void
  abstract release(): void
  abstract reset(): void
  abstract prepare(): void
  abstract create(): void
  abstract init(): void
  abstract updatePlaybackSpeed(speed: number): void
  abstract getAudioTrackList(): void
  abstract getSubtitleTrackList(): void
  abstract selectAudioTrack(index: number): void
  abstract selectSubtitleTrack(index: number): void
  abstract setRotation(): void
  abstract getData(): void
  abstract setPlayerCallback(pathStack: NavPathStack): void
  abstract initAVSession(): Promise<void>
  abstract setSessionListener(): void
  abstract setExternalSubtitle(nowPlaying: VideoMetadata): void
  abstract onAppear(): Promise<void>
  abstract onDisappear(): void
  abstract onWillDisappear(): Promise<void>
  abstract playChooseVideo(item: VideoMetadata, pathStack: NavPathStack): void
  abstract playNextVideoProcess(pathStack: NavPathStack): void
  abstract videoStartPlayTime(seekMode: number): void
}
