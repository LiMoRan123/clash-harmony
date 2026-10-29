import { ConnectionViewState, TrafficViewState } from '../models/HomeViewState';
import { AppTheme } from '../theme/AppTheme';

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
  @Prop exitIp: string = '';
  @Prop checkingExit: boolean = false;
  @Prop startBlocked: boolean = false;
  onToggle: () => void = () => {};
  onCheckExit: () => void = () => {};

  build() {
    Column({ space: 12 }) {
      Row({ space: 16 }) {
        Column({ space: 6 }) {
          Row({ space: 6 }) {
            Circle().width(6).height(6).fill(this.connection.connected ? AppTheme.success : AppTheme.muted)
              .accessibilityLevel('no')
            Text('VPN 运行状态').fontSize(12).fontColor(AppTheme.muted)
          }
          Text(this.connection.busy ? this.connection.message : this.connection.connected ? '已连接' :
            this.connection.phase === 'error' ? '连接未完成' : '未连接')
            .fontSize(26).fontWeight(FontWeight.Medium).fontColor(AppTheme.text).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button({ type: ButtonType.Circle }) {
          if (this.connection.busy) {
            LoadingProgress().width(28).height(28).color(AppTheme.onPrimary)
          } else {
            Image($r('app.media.ui_power')).width(30).height(30).fillColor(AppTheme.onPrimary).accessibilityLevel('no')
          }
        }.width(64).height(64).backgroundColor(AppTheme.primary)
          .enabled(!this.connection.busy && (this.connection.connected || !this.startBlocked))
          .accessibilityText(this.connection.busy ? this.connection.message : this.connection.connected ? '断开 VPN' :
            this.startBlocked ? '配置处理中，完成后可连接' : '连接 VPN')
          .onClick(() => { this.onToggle() })
      }.width('100%').constraintSize({ minHeight: 72 })
      Divider().color(AppTheme.outline)
      ConnectionCounters({ traffic: this.traffic })
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          if (this.checkingExit) {
            LoadingProgress().width(17).height(17).color(AppTheme.primary)
          } else {
            Image($r('app.media.ui_globe')).width(17).height(17).fillColor(AppTheme.muted).accessibilityLevel('no')
          }
          Text(this.checkingExit ? '正在检测出口…' : this.exitIp.length > 0 && this.connection.connected ?
            this.exitIp : this.connection.connected ? '检测出口 IP' : '连接后可检测出口 IP')
            .fontSize(12).fontColor(this.connection.connected ? AppTheme.primary : AppTheme.muted)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          if (this.connection.connected) {
            Image($r('app.media.ui_refresh')).width(16).height(16).fillColor(AppTheme.primary).accessibilityLevel('no')
          }
        }.width('100%')
      }.width('100%').height(44).padding({ left: 12, right: 12 }).borderRadius(12)
        .backgroundColor(AppTheme.variant).enabled(this.connection.connected && !this.connection.busy && !this.checkingExit)
        .accessibilityText('检测代理出口 IP').onClick(() => { this.onCheckExit() })
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
  private SpeedTile(label: string, value: string, history: number[], icon: Resource, tone: ResourceColor) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Image(icon).width(16).height(16).fillColor(tone).accessibilityLevel('no')
        Text(label).fontSize(12).fontColor(AppTheme.muted)
      }.width('100%')
      Text() {
        Span(value.split(' ')[0]).fontSize(25).fontWeight(FontWeight.Medium).fontColor(AppTheme.text)
        Span(' ' + (value.split(' ')[1] ?? 'B/s')).fontSize(12).fontColor(AppTheme.muted)
      }.maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      TrafficSparkline({ samples: history, lineColor: tone })
    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      .accessibilityGroup(true).accessibilityText(label + '速度 ' + value)
  }

  build() {
    Row({ space: 16 }) {
      this.SpeedTile('上传', this.traffic.uploadSpeed, this.traffic.uploadHistory, $r('app.media.ui_up'), AppTheme.muted)
      Divider().vertical(true).height(76).color(AppTheme.outline)
      this.SpeedTile('下载', this.traffic.downloadSpeed, this.traffic.downloadHistory, $r('app.media.ui_down'), AppTheme.primary)
    }.width('100%').padding(20).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
  }
}
