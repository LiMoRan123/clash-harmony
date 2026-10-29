import { SubscriptionInfo } from '../models/Profile';
import { SubscriptionInfoService } from '../services/SubscriptionInfoService';
import { AppTheme } from '../theme/AppTheme';

@Component
export struct SubscriptionDetails {
  @Prop info: SubscriptionInfo = {};
  @Prop checkedAt: number = 0;

  build() {
    Column({ space: 7 }) {
      if (Object.keys(this.info).length === 0) {
        Text(this.checkedAt > 0 ? '服务商未提供有效的流量与到期信息' : '更新订阅后可获取流量与到期信息')
          .fontSize(12).fontColor(AppTheme.muted).maxLines(2).width('100%')
      } else {
        Text(SubscriptionInfoService.usageText(this.info)).fontSize(12)
          .fontColor(SubscriptionInfoService.exhausted(this.info) ? AppTheme.danger : AppTheme.muted)
          .maxLines(2).width('100%')
        if (SubscriptionInfoService.usagePercent(this.info) !== undefined) {
          Progress({ value: SubscriptionInfoService.usagePercent(this.info) ?? 0, total: 100, type: ProgressType.Linear })
            .width('100%').height(4).backgroundColor(AppTheme.outline)
            .color(SubscriptionInfoService.exhausted(this.info) ? AppTheme.danger : AppTheme.primary)
            .accessibilityText(SubscriptionInfoService.usageText(this.info))
        }
        Text(SubscriptionInfoService.expiryText(this.info)).fontSize(12)
          .fontColor(SubscriptionInfoService.expired(this.info) ? AppTheme.danger : AppTheme.muted)
          .maxLines(2).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
