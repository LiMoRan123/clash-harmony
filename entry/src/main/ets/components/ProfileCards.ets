import { ClashProfile, formatProfileUpdatedAt } from '../models/Profile';
import { ProfileUpdateViewState } from '../models/ProfileUpdateViewState';
import { AppTheme } from '../theme/AppTheme';
import { SubscriptionDetails } from './SubscriptionDetails';

@Component
export struct ProfileUpdateBanner {
  @ObjectLink update: ProfileUpdateViewState;

  build() {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        if (this.update.running) {
          LoadingProgress().width(22).height(22).color(AppTheme.primary)
        } else {
          Image(!this.update.failed ?
            $r('app.media.ui_check') : $r('app.media.ui_info'))
            .width(22).height(22).fillColor(!this.update.failed ?
              AppTheme.success : AppTheme.danger).accessibilityLevel('no')
        }
        Column({ space: 4 }) {
          Text(this.update.running ? this.update.batch ? '正在更新订阅' : '正在更新配置' : '上次更新结果')
            .fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.text)
          Text(this.update.message).fontSize(12).fontColor(AppTheme.muted).maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.update.batch && this.update.running) {
          Text('已完成 ' + this.update.completed + '/' + this.update.targetUids.length).fontSize(12).fontColor(AppTheme.primary)
        }
      }.width('100%')
      if (this.update.batch && this.update.running) {
        Progress({ value: this.update.completed, total: this.update.targetUids.length, type: ProgressType.Linear })
          .width('100%').color(AppTheme.primary).backgroundColor(AppTheme.outline)
      }
    }.width('100%').padding(16).backgroundColor(AppTheme.variant).borderRadius(18)
      .accessibilityGroup(true).accessibilityText(this.update.message)
  }
}

@Component
export struct ProfileListCard {
  @Prop profile: ClashProfile = {
    uid: '', name: '', type: 'remote', source: '', filePath: '', updatedAt: 0, nodeCount: 0, traffic: ''
  };
  @Prop current: boolean = false;
  @Prop mutating: boolean = false;
  @ObjectLink update: ProfileUpdateViewState;
  menu: MenuElement[] = [];
  onActivate: () => void = () => {};
  onUpdate: () => void = () => {};
  onEdit: () => void = () => {};

  build() {
    Column({ space: 4 }) {
      Row({ space: 4 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 12 }) {
            Stack() {
              Circle().width(21).height(21).fill(Color.Transparent)
                .stroke(this.current ? AppTheme.primary : AppTheme.muted).strokeWidth(2)
              if (this.current) { Circle().width(11).height(11).fill(AppTheme.primary) }
            }.width(24).height(24).accessibilityLevel('no')
            Column({ space: 6 }) {
              Text(this.profile.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor(AppTheme.text)
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
              Text((this.profile.type === 'remote' ? '远程订阅' : '本地配置') + ' · ' + this.profile.nodeCount + ' 个节点')
                .fontSize(12).fontColor(AppTheme.muted).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          }.width('100%')
        }.layoutWeight(1).constraintSize({ minHeight: 64 }).padding({ left: 0, right: 4, top: 8, bottom: 8 })
          .backgroundColor(Color.Transparent).borderRadius(12).enabled(!this.update.running && !this.mutating)
          .accessibilityText(this.profile.name + (this.current ? '，当前配置' : '，点击启用'))
          .onClick(() => { if (!this.current) { this.onActivate() } })
        Button({ type: ButtonType.Circle }) {
          if (this.update.phaseFor(this.profile.uid) === 'updating') {
            LoadingProgress().width(22).height(22).color(AppTheme.primary)
          } else {
            Image(this.profile.type === 'remote' ? $r('app.media.ui_refresh') : $r('app.media.ui_edit'))
              .width(21).height(21).fillColor(AppTheme.primary).accessibilityLevel('no')
          }
        }.width(48).height(48).backgroundColor(Color.Transparent).enabled(!this.update.running && !this.mutating)
          .accessibilityText(this.profile.name + (this.profile.type === 'remote' ? '，更新订阅' : '，编辑配置'))
          .onClick(() => { if (this.profile.type === 'remote') { this.onUpdate() } else { this.onEdit() } })
        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.ui_more')).width(22).height(22).fillColor(AppTheme.muted).accessibilityLevel('no')
        }.width(48).height(48).backgroundColor(Color.Transparent).enabled(!this.update.running && !this.mutating)
          .accessibilityText(this.profile.name + '，更多操作').bindMenu(this.menu)
      }.width('100%')
      if (this.profile.type === 'remote') {
        Column() {
          SubscriptionDetails({ info: this.profile.subscriptionInfo ?? {},
            checkedAt: this.profile.subscriptionInfoCheckedAt ?? 0 })
        }.width('100%').padding({ left: 36, right: 8, top: 4, bottom: 8 })
      }
      Row({ space: 8 }) {
        Text(this.update.phaseFor(this.profile.uid) === 'updating' || this.update.phaseFor(this.profile.uid) === 'queued' ?
          this.update.messageFor(this.profile.uid) : formatProfileUpdatedAt(this.profile.updatedAt))
          .fontSize(12).fontColor(this.update.phaseFor(this.profile.uid) === 'updating' ? AppTheme.primary : AppTheme.muted)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        if (this.current) {
          Text('当前配置').fontSize(12).fontWeight(FontWeight.Medium).fontColor(AppTheme.primary)
        }
      }.width('100%').padding({ left: 36, right: 4 })
      if (this.update.phaseFor(this.profile.uid) === 'error') {
        Text(this.update.messageFor(this.profile.uid)).fontSize(12).fontColor(AppTheme.danger)
          .maxLines(3).width('100%').padding({ left: 36, top: 6, bottom: 4 })
      }
    }.width('100%').padding({ left: 16, right: 8, top: 8, bottom: 16 })
      .backgroundColor(this.current ? AppTheme.selectedSurface : AppTheme.surface).borderRadius(AppTheme.rowRadius)
      .border({ width: this.current ? 1.5 : 1, color: this.current ? AppTheme.primary : AppTheme.outline })
  }
}
