import { HomeNetworkViewState, DashboardServiceResult } from '../models/HomeNetworkViewState';
import { ClashProfile, formatProfileUpdatedAt } from '../models/Profile';
import { AppTheme } from '../theme/AppTheme';
import { SubscriptionDetails } from './SubscriptionDetails';

@Component
export struct HomeProfileCard {
  @Prop profile: ClashProfile;
  onOpen: () => void = () => {};

  build() {
    Column({ space: 12 }) {
      Button({ type: ButtonType.Normal }) {
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Image($r('app.media.ui_file')).width(18).height(18).fillColor(AppTheme.primary).accessibilityLevel('no')
            Text('当前配置').fontSize(13).fontColor(AppTheme.muted).layoutWeight(1)
            Image($r('app.media.ui_chevron')).width(18).height(18).fillColor(AppTheme.muted).accessibilityLevel('no')
          }.width('100%')
          Text(this.profile.name).fontSize(18).fontWeight(FontWeight.Medium).fontColor(AppTheme.text)
            .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.profile.uid.length === 0 ? '点击添加或启用配置' :
            `${this.profile.nodeCount} 个节点 · ${this.profile.updatedAt > 0 ? '更新于 ' : ''}${formatProfileUpdatedAt(this.profile.updatedAt)}`)
            .fontSize(12).fontColor(AppTheme.muted).maxLines(2).width('100%')
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').constraintSize({ minHeight: 80 }).padding(0).backgroundColor(Color.Transparent)
        .accessibilityText('当前配置，' + this.profile.name + '，点击管理').onClick(() => { this.onOpen() })
      if (this.profile.type === 'remote') {
        Divider().color(AppTheme.outline)
        SubscriptionDetails({ info: this.profile.subscriptionInfo ?? {}, checkedAt: this.profile.subscriptionInfoCheckedAt ?? 0 })
      }
    }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
  }
}

@Component
export struct HomeServiceCard {
  @ObjectLink network: HomeNetworkViewState;
  @Prop connected: boolean = false;
  onRefresh: () => void = () => {};

  private resultLabel(item: DashboardServiceResult): string {
    if (!this.connected) { return '等待连接' }
    if (item.status === 'checking') { return '检测中…' }
    if (item.status === 'available') { return item.delay + ' ms' }
    if (item.status === 'restricted') { return '响应受限 · ' + item.code }
    return item.status === 'unreachable' ? '连接超时或失败' : '等待检测';
  }

  private resultColor(item: DashboardServiceResult): ResourceColor {
    if (!this.connected) { return AppTheme.muted }
    if (item.status === 'available') { return AppTheme.success }
    if (item.status === 'restricted') { return AppTheme.warning }
    if (item.status === 'unreachable') { return AppTheme.danger }
    return AppTheme.muted;
  }

  @Builder
  private ServiceTile(item: DashboardServiceResult) {
    Column({ space: 6 }) {
      Text(item.name).fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.text).maxLines(1)
      Row({ space: 5 }) {
        if (item.status === 'checking' && this.connected) {
          LoadingProgress().width(13).height(13).color(AppTheme.primary)
        }
        Text(this.resultLabel(item)).fontSize(12).fontColor(this.resultColor(item)).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      }.width('100%')
    }.layoutWeight(1).alignItems(HorizontalAlign.Start).padding(12)
      .constraintSize({ minHeight: 72 }).backgroundColor(AppTheme.variant).borderRadius(16)
      .accessibilityGroup(true).accessibilityText(item.name + '，' + this.resultLabel(item))
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Image($r('app.media.ui_shield')).width(18).height(18).fillColor(AppTheme.muted).accessibilityLevel('no')
        Column({ space: 4 }) {
          Text('服务状态').fontSize(15).fontWeight(FontWeight.Medium).fontColor(AppTheme.text)
          Text(this.network.summary()).fontSize(12).fontColor(AppTheme.muted)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button({ type: ButtonType.Circle }) {
          if (this.network.checkingServices || this.network.checkingExit) {
            LoadingProgress().width(20).height(20).color(AppTheme.primary)
          } else {
            Image($r('app.media.ui_refresh')).width(20).height(20).fillColor(AppTheme.primary).accessibilityLevel('no')
          }
        }.width(48).height(48).backgroundColor(AppTheme.variant)
          .enabled(this.connected && !this.network.checkingExit && !this.network.checkingServices)
          .accessibilityText('刷新服务状态与出口 IP').onClick(() => { this.onRefresh() })
      }.width('100%')
      Row({ space: 10 }) {
        this.ServiceTile(this.network.services[0])
        this.ServiceTile(this.network.services[1])
      }.width('100%').alignItems(VerticalAlign.Top)
      Row({ space: 10 }) {
        this.ServiceTile(this.network.services[2])
        this.ServiceTile(this.network.services[3])
      }.width('100%').alignItems(VerticalAlign.Top)
      Text('按当前分流规则检测，不代表账号登录或地区解锁状态')
        .fontSize(12).fontColor(AppTheme.muted).width('100%').maxLines(2)
    }.width('100%').padding(18).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
  }
}
