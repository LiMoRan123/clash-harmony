import { ConnectionViewState, TrafficViewState } from '../models/HomeViewState';
import { AppTheme } from '../theme/AppTheme';
import { HomeNetworkViewState } from '../models/HomeNetworkViewState';
import { SubscriptionInfoService } from '../services/SubscriptionInfoService';

@Component
struct ConnectionCounters {
  @ObjectLink traffic: TrafficViewState;
  build() {
    Row() {
      Column({ space: 4 }) {
        Text('运行时间').fontSize(12).fontColor(AppTheme.muted)
        Text(this.traffic.uptime).fontSize(17).fontWeight(FontWeight.Medium).fontColor(AppTheme.text).maxLines(1)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Column({ space: 4 }) {
        Text('活跃连接').fontSize(12).fontColor(AppTheme.muted)
        Text(this.traffic.connections.toString()).fontSize(17).fontWeight(FontWeight.Medium).fontColor(AppTheme.text)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }.width('100%')
  }
}

@Component
export struct HomeConnectionCard {
  @ObjectLink connection: ConnectionViewState;
  @ObjectLink traffic: TrafficViewState;
  @ObjectLink network: HomeNetworkViewState;
  @Prop startBlocked: boolean = false;
  onToggle: () => void = () => {};
  onCheckExit: () => void = () => {};

  private statusLabel(): string {
    if (this.connection.busy) { return this.connection.phase === 'stopping' ? '正在断开' : '正在连接' }
    return this.connection.connected ? '运行中' : this.connection.phase === 'error' ? '连接异常' : '未连接';
  }

  private headline(): string {
    if (this.connection.busy) { return this.connection.message }
    if (!this.connection.connected) { return '准备好，随时连接' }
    if (this.network.checkingExit) { return '正在检测出口…' }
    return this.network.exitIp.length > 0 ? this.network.exitIp : '出口 IP 暂不可用';
  }

  build() {
    Column({ space: 16 }) {
      Row({ space: 8 }) {
        Image($r('app.media.ui_activity')).width(18).height(18).fillColor(AppTheme.muted).accessibilityLevel('no')
        Text('状态').fontSize(13).fontColor(AppTheme.muted)
        Text(this.statusLabel()).fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor(this.connection.connected ? AppTheme.success :
            this.connection.phase === 'error' ? AppTheme.danger : AppTheme.muted)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.connection.connected ? AppTheme.successContainer : AppTheme.variant).borderRadius(16)
        Blank()
        Text('VPN').fontSize(12).fontColor(AppTheme.muted)
      }.width('100%')
      Row({ space: 12 }) {
        Column({ space: 8 }) {
          Text(this.headline()).fontSize(24).minFontSize(16).maxFontSize(24)
            .heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST)
            .fontWeight(FontWeight.Medium).fontColor(AppTheme.text).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          Text(this.connection.connected ? '当前出口 IP' : '选择配置后点击右侧连接')
            .fontSize(12).fontColor(AppTheme.muted).maxLines(2)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column({ space: 6 }) {
          Button({ type: ButtonType.Circle }) {
            if (this.connection.busy) {
              LoadingProgress().width(30).height(30).color(AppTheme.onPrimary)
            } else {
              Image(this.connection.connected ? $r('app.media.ui_pause') : $r('app.media.ui_play'))
                .width(32).height(32).fillColor(this.connection.connected ? AppTheme.onPrimary : AppTheme.primary)
                .accessibilityLevel('no')
            }
          }.width(72).height(72)
            .backgroundColor(this.connection.busy || this.connection.connected ? AppTheme.primary : AppTheme.variant)
            .border({ width: this.connection.connected || this.connection.busy ? 0 : 1, color: AppTheme.outline })
            .enabled(!this.connection.busy && (this.connection.connected || !this.startBlocked))
            .accessibilityText(this.connection.busy ? this.connection.message : this.connection.connected ? '断开 VPN' :
              this.startBlocked ? '配置处理中，完成后可连接' : '连接 VPN')
            .onClick(() => { this.onToggle() })
          Text(this.connection.busy ? '请稍候' : this.connection.connected ? '点击断开' : '点击连接')
            .fontSize(12).fontColor(AppTheme.muted)
        }
      }.width('100%').constraintSize({ minHeight: 96 })
      ConnectionCounters({ traffic: this.traffic })
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          if (this.network.checkingExit) {
            LoadingProgress().width(17).height(17).color(AppTheme.primary)
          } else {
            Image($r('app.media.ui_globe')).width(17).height(17).fillColor(AppTheme.muted).accessibilityLevel('no')
          }
          Text(this.network.exitMessage).fontSize(12).fontColor(AppTheme.muted)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          if (this.connection.connected) {
            Image($r('app.media.ui_refresh')).width(16).height(16).fillColor(AppTheme.primary).accessibilityLevel('no')
          }
        }.width('100%')
      }.width('100%').constraintSize({ minHeight: 44 }).padding({ left: 10, right: 10, top: 8, bottom: 8 }).borderRadius(12)
        .backgroundColor(AppTheme.variant)
        .enabled(this.connection.connected && !this.connection.busy && !this.network.checkingExit && !this.network.checkingServices)
        .accessibilityText('重新检测出口 IP 与服务状态').onClick(() => { this.onCheckExit() })
    }.width('100%').padding(20).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
  }
}

@Component
struct TrafficSparkline {
  @Prop samples: number[] = [];
  @Prop lineColor: ResourceColor = AppTheme.primary;
  @State private availableWidth: number = 128;

  private points(): [number, number][] {
    const maximum: number = Math.max(8192, ...this.samples);
    const points: [number, number][] = [];
    for (let index = 0; index < this.samples.length; index++) {
      points.push([index / Math.max(1, this.samples.length - 1) * this.availableWidth,
        30 - Math.min(1, Math.max(0, this.samples[index]) / maximum) * 27]);
    }
    return points;
  }

  build() {
    Stack() {
      if (this.samples.some((value: number) => value > 0)) {
        Polyline().points(this.points()).width('100%').height(32).fill(Color.Transparent)
          .stroke(this.lineColor).strokeWidth(2).accessibilityLevel('no')
      }
    }.width('100%').height(32).clip(true).accessibilityLevel('no')
      .onAreaChange((oldArea: Area, newArea: Area) => {
        const width: number = Number(newArea.width);
        if (width > 0 && Math.abs(width - this.availableWidth) > 0.5) { this.availableWidth = width }
      })
  }
}

@Component
export struct HomeTrafficCard {
  @ObjectLink traffic: TrafficViewState;

  @Builder
  private SpeedTile(label: string, value: string, total: number, peak: number, history: number[], icon: Resource, tone: ResourceColor) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Image(icon).width(16).height(16).fillColor(tone).accessibilityLevel('no')
        Text(label).fontSize(12).fontColor(AppTheme.muted)
      }.width('100%')
      Text() {
        Span(value.split(' ')[0]).fontSize(25).fontWeight(FontWeight.Medium).fontColor(AppTheme.text)
        Span(' ' + (value.split(' ')[1] ?? 'B/s')).fontSize(12).fontColor(AppTheme.muted)
      }.maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      Text('累计 ' + SubscriptionInfoService.formatBytes(total)).fontSize(12).fontColor(AppTheme.muted).maxLines(1)
      Text('峰值 ' + SubscriptionInfoService.formatBytes(Math.round(peak)) + '/s').fontSize(12).fontColor(AppTheme.muted).maxLines(1)
      TrafficSparkline({ samples: history, lineColor: tone })
    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      .accessibilityGroup(true).accessibilityText(label + '速度 ' + value + '，累计 ' +
        SubscriptionInfoService.formatBytes(total) + '，峰值 ' + SubscriptionInfoService.formatBytes(Math.round(peak)) + '每秒')
  }

  build() {
    Row({ space: 16 }) {
      this.SpeedTile('上传', this.traffic.uploadSpeed, this.traffic.uploadTotal, this.traffic.uploadPeak, this.traffic.uploadHistory, $r('app.media.ui_up'), AppTheme.muted)
      Divider().vertical(true).height(120).color(AppTheme.outline)
      this.SpeedTile('下载', this.traffic.downloadSpeed, this.traffic.downloadTotal, this.traffic.downloadPeak, this.traffic.downloadHistory, $r('app.media.ui_down'), AppTheme.primary)
    }.width('100%').padding(20).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
  }
}
