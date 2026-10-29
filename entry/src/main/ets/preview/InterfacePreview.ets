// DevEco-only fixtures for the production components. These previews do not
// start a VPN, access subscriptions or make network requests.
import { HomeConnectionCard, HomeTrafficCard } from '../components/HomeRuntimeCards';
import { AppNavigationBar } from '../components/AppNavigationBar';
import { ProfileListCard, ProfileUpdateBanner } from '../components/ProfileCards';
import { ConnectionViewState, TrafficViewState } from '../models/HomeViewState';
import { HomeNetworkViewState } from '../models/HomeNetworkViewState';
import { HomeServiceCard } from '../components/HomeOverviewCards';
import { ProfileUpdateViewState } from '../models/ProfileUpdateViewState';
import { ClashProfile } from '../models/Profile';
import { AppTheme } from '../theme/AppTheme';

@Preview({ title: '运行卡片 · 360', width: 360, height: 740 })
@Component
struct RuntimeCardsPreview {
  @State private connection: ConnectionViewState = new ConnectionViewState();
  @State private traffic: TrafficViewState = new TrafficViewState();
  @State private network: HomeNetworkViewState = new HomeNetworkViewState();

  aboutToAppear(): void {
    this.connection.connected = true;
    this.connection.setPhase('connected', '已连接');
    this.traffic.uptime = '00:12:36';
    this.traffic.connections = 8;
    this.network.exitIp = '203.0.113.42';
    this.network.exitMessage = '出口 IP · 自动检测';
    this.network.checkedAt = 1700000000000;
    this.network.services = [
      { key: 'google', name: 'Google', status: 'available', delay: 178, code: 204 },
      { key: 'github', name: 'GitHub', status: 'available', delay: 301, code: 200 },
      { key: 'youtube', name: 'YouTube', status: 'available', delay: 277, code: 204 },
      { key: 'chatgpt', name: 'ChatGPT', status: 'restricted', delay: 308, code: 403 }
    ];
    this.traffic.recordTotals(512 * 1024 * 1024, 32 * 1024 * 1024, 1024 * 1024, 32768);
    this.traffic.uploadSpeed = '24.8 KB/s';
    this.traffic.downloadSpeed = '1.2 MB/s';
    this.traffic.uploadHistory = [0, 8192, 4096, 16384, 12288, 8192, 4096, 8192, 16384, 24576, 8192, 4096];
    this.traffic.downloadHistory = [0, 32768, 8192, 16384, 65536, 131072, 65536, 32768, 8192, 16384, 32768, 65536];
  }

  build() {
    Column() {
      Text('仪表盘').fontSize(24).fontWeight(FontWeight.Medium).fontColor(AppTheme.text)
        .width('100%').height(64).padding({ left: 16, right: 16 })
      Scroll() {
        Column({ space: 12 }) {
          HomeConnectionCard({ connection: this.connection, traffic: this.traffic, network: this.network })
          HomeTrafficCard({ traffic: this.traffic })
          HomeServiceCard({ network: this.network, connected: true })
        }.width('100%').padding(16)
      }.layoutWeight(1).width('100%').align(Alignment.Top)
      AppNavigationBar({ selected: 'home' })
    }.width('100%').height('100%').backgroundColor(AppTheme.background)
  }
}

@Preview({ title: '未连接 · 360', width: 360, height: 600 })
@Component
struct DisconnectedRuntimePreview {
  @State private connection: ConnectionViewState = new ConnectionViewState();
  @State private traffic: TrafficViewState = new TrafficViewState();
  @State private network: HomeNetworkViewState = new HomeNetworkViewState();

  build() {
    Column({ space: 12 }) {
      HomeConnectionCard({ connection: this.connection, traffic: this.traffic, network: this.network })
      HomeTrafficCard({ traffic: this.traffic })
    }.width('100%').padding(16).backgroundColor(AppTheme.background)
  }
}

@Preview({ title: '配置更新 · 360', width: 360, height: 800 })
@Component
struct ProfileCardsPreview {
  @State private updating: ProfileUpdateViewState = new ProfileUpdateViewState();
  @State private failed: ProfileUpdateViewState = new ProfileUpdateViewState();
  private first: ClashProfile = { uid: 'preview-1', name: '演示订阅 · 较长的配置名称用于检查换行',
    type: 'remote', source: '', filePath: '', updatedAt: 0, nodeCount: 36, traffic: '',
    subscriptionInfo: { upload: 1073741824, download: 2147483648, total: 10737418240, expire: 1894665600 },
    subscriptionInfoCheckedAt: 1700000000000 };
  private second: ClashProfile = { uid: 'preview-2', name: '另一份演示订阅',
    type: 'remote', source: '', filePath: '', updatedAt: 0, nodeCount: 8, traffic: '' };

  aboutToAppear(): void {
    this.updating.begin(['preview-1', 'preview-2'], true);
    this.updating.downloading('preview-1', this.first.name);
    this.failed.begin(['preview-2']);
    this.failed.complete('preview-2', false, '订阅服务器返回 HTTP 503，请稍后重试');
    this.failed.finish('更新失败，请稍后重试');
  }

  build() {
    Column() {
      Text('配置').fontSize(24).fontWeight(FontWeight.Medium).fontColor(AppTheme.text)
        .width('100%').height(64).padding({ left: 16, right: 16 })
      Scroll() {
        Column({ space: 12 }) {
          ProfileUpdateBanner({ update: this.updating })
          ProfileListCard({ profile: this.first, current: true, update: this.updating })
          ProfileListCard({ profile: this.second, update: this.updating })
          Text('失败状态示例').fontSize(13).fontColor(AppTheme.muted).width('100%').margin({ top: 12 })
          ProfileListCard({ profile: this.second, update: this.failed })
        }.width('100%').padding(16)
      }.layoutWeight(1).width('100%').align(Alignment.Top)
      AppNavigationBar({ selected: 'profiles', updating: true })
    }.width('100%').height('100%').backgroundColor(AppTheme.background)
  }
}
