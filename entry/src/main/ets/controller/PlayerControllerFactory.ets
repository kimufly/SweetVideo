import { VideoMetadata } from '../interfaces/VideoMetadataInterface'
import { AVPlayerController } from './AVPlayerController'
import { MpvController } from './MpvController/MpvController'
import { SweetRepeatMode } from '../common/enum/SweetRepeatMode'

// 产品接口 interface
export interface PlayerControllerInterface {
  backForward(): void

  fastForward(): void

  prepare(): void

  play(): void

  pause(): void

  reset(): void

  release(): void

  init(): void

  create(): void

  seekTime(seekTime: number): void

  togglePlayback(): void

  videoStartPlayTime(seekMode: number): void

  getAudioTrackList(): void

  selectAudioTrack(trackId: number): void

  initAVSession(): Promise<void>

  setSessionListener(): void

  setRotation(): void

  onScreenDoubleClick(tapX: number): void

  getSubtitleTrackList(): void

  selectSubtitleTrack(trackId: number): void

  initVolumeAndBrightness(): Promise<void>

  getData(): void

  setPlayerCallback(pathStack: NavPathStack): void

  updatePlaybackSpeed(speed: number): void

  playNextVideo(repeatMode: SweetRepeatMode): VideoMetadata | undefined

  setExternalSubtitle(nowPlaying: VideoMetadata): void

  playNextVideoProcess(pathStack: NavPathStack): void

  playChooseVideo(item: VideoMetadata, pathStack: NavPathStack): void

  // Pinch（捏合缩放）
  onPinchStart(fingerDistance: number): void
  onPinchUpdate(fingerDistance: number): void
  onPinchEnd(): void

  // Horizontal pan（进度滑动）
  onHorizonPanStart(): void
  onHorizonPanUpdate(offsetX: number): void
  onHorizonPanEnd(): void

  // Vertical pan（亮度/音量）
  onVerticalPanStart(tapX: number): void
  onVerticalPanUpdate(offsetY: number): void
  onVerticalPanEnd(): void

  // Long press（长按加速）
  onLongPressAction(): void
  onLongPressEnd(): void
  onLongPressPanStart(tapX: number): void
  onLongPressPanUpdate(tapX: number): void

  // Pan move（缩放后平移）
  onPanMoveStart(event: GestureEvent): void
  onPanMoveUpdate(event: GestureEvent): void

  // Screen proportion（屏幕比例）
  onSpecificVideoProportions(playAreaSize: number[]): void
  onOriginalRatio(): void
  onStretchedToFullScreen(): void
  onFullScreenByWidth(): void
  onFullScreenByHeight(): void
  onUniformScale(scale: number): void

  onVolumeKeyEvent(event: KeyEvent): void
  handleAreaChange(newValue: Area): void

  onAppear(): Promise<void>
  onDisappear(): void
  onWillDisappear(): Promise<void>
}

// 真正的工厂 controller
export class PlayerControllerFactory {
  static createAVPlayerController(): AVPlayerController {
    return new AVPlayerController()
  }

  static createMpvController(): MpvController {
    return new MpvController()
  }
}