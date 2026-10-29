import { AppTheme } from '../theme/AppTheme';

interface Destination {
  key: string;
  label: string;
  icon: Resource;
}

const DESTINATIONS: Destination[] = [
  { key: 'home', label: '仪表盘', icon: $r('app.media.ui_home') },
  { key: 'proxies', label: '代理', icon: $r('app.media.ui_globe') },
  { key: 'profiles', label: '配置', icon: $r('app.media.ui_file') },
  { key: 'diagnostics', label: '工具', icon: $r('app.media.ui_tools') }
];

@Component
export struct AppNavigationBar {
  @Prop selected: string = 'home';
  @Prop updating: boolean = false;
  onNavigate: (key: string) => void = () => {};

  build() {
    Column() {
      Divider().strokeWidth(0.5).color(AppTheme.outline)
      Row() {
        ForEach(DESTINATIONS, (item: Destination) => {
          Button({ type: ButtonType.Normal }) {
            Column({ space: 4 }) {
              Stack() {
                if (item.key === 'profiles' && this.updating) {
                  LoadingProgress().width(22).height(22)
                    .color(this.selected === item.key ? AppTheme.onPrimaryContainer : AppTheme.primary)
                } else {
                  Image(item.icon).width(23).height(23)
                    .fillColor(this.selected === item.key ? AppTheme.onPrimaryContainer : AppTheme.muted)
                    .accessibilityLevel('no')
                }
              }.width(64).height(32).borderRadius(16)
                .backgroundColor(this.selected === item.key ? AppTheme.primaryContainer : Color.Transparent)
              Text(item.label).fontSize(12)
                .fontWeight(this.selected === item.key ? FontWeight.Bold : FontWeight.Medium)
                .fontColor(this.selected === item.key ? AppTheme.text : AppTheme.muted)
            }.width('100%')
          }.constraintSize({ minHeight: 72 }).layoutWeight(1).padding(0).borderRadius(16).backgroundColor(Color.Transparent)
            .accessibilityText(item.label + (this.selected === item.key ? '，已选中' : '') +
              (item.key === 'profiles' && this.updating ? '，配置更新中' : ''))
            .onClick(() => { this.onNavigate(item.key) })
        }, (item: Destination) => item.key)
      }.width('100%').constraintSize({ maxWidth: AppTheme.contentMaxWidth }).padding({ left: 8, right: 8 })
    }.width('100%').padding({ bottom: 4 }).backgroundColor(AppTheme.surface)
  }
}
