import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { AppTheme } from '../theme/AppTheme';
import { ConnectionViewState, TrafficViewState } from '../models/HomeViewState';
import { ProfileUpdateViewState } from '../models/ProfileUpdateViewState';
import { HomeConnectionCard, HomeTrafficCard } from '../components/HomeRuntimeCards';
import { AppNavigationBar } from '../components/AppNavigationBar';
import { ProfileListCard, ProfileUpdateBanner } from '../components/ProfileCards';
import { ControllerStreamService } from '../services/ControllerStreamService';
import { VpnRuntimeEvent, VpnRuntimeEvents } from '../services/VpnRuntimeEvents';
import { VpnControlChannel } from '../services/VpnControlChannel';
import { VpnBackgroundService } from '../services/VpnBackgroundService';
import { RuntimeDiagnostics } from '../services/RuntimeDiagnostics';
import { AppPreferences, AppPreferencesService, defaultAppPreferences } from '../services/AppPreferencesService';
import { DocumentExportService } from '../services/DocumentExportService';
import { AppBackupService } from '../services/AppBackupService';
import { NetworkProbeService } from '../services/NetworkProbeService';
import { GenericSubscriptionConverterService } from '../services/GenericSubscriptionConverterService';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ClashConfigParserService, ParsedConfigSummary, ParsedProxyNode } from '../services/ClashConfigParserService';
import { ClipboardImportResult, ClipboardImportService } from '../services/ClipboardImportService';
import { CoreBridgeService, CoreBridgeState } from '../services/CoreBridgeService';
import { CoreService, CoreSummary } from '../services/CoreService';
import { ClashProfile, createEmptyProfileState, createRemoteProfile, formatProfileUpdatedAt, ProfileState } from '../models/Profile';
import {
  ConnectionInfo as ControllerConnectionInfo,
  ControllerStatus,
  ControllerTextResult,
  MihomoControllerService,
  ProxyGroupInfo
} from '../services/MihomoControllerService';
import { FileImportResult, LocalFileImportService } from '../services/LocalFileImportService';
import { ProfileStore } from '../services/ProfileStore';
import { RuntimeConfigResult, RuntimeConfigService } from '../services/RuntimeConfigService';
import { SubscriptionService, SubscriptionUpdateResult } from '../services/SubscriptionService';
import {
  ConnectionInfo as PollerConnectionInfo,
  TrafficPollerService,
  TrafficSnapshot
} from '../services/TrafficPollerService';
import { VpnService } from '../services/VpnService';
import { TcpDelayTestService } from '../services/TcpDelayTestService';

interface ProxyNode {
  name: string;
  meta: string;
  delay: string;
  selected?: boolean;
  status?: string;
  server?: string;
  port?: number;
}

interface ProxyDelayState {
  delay: string;
  status: string;
}

interface ProxyDelayUpdate {
  name: string;
  delay: string;
  status: string;
}

interface SpeedTestBlockedState {
  nodeDelay: string;
  nodeStatus: string;
  statusMessage: string;
  progress: string;
  summary: string;
}

interface RuntimeConnectionRow {
  id: string;
  target: string;
  chain: string;
  rule: string;
  upload: string;
  download: string;
}

interface RuntimeTunStatus {
  ready: boolean;
  message: string;
  raw: string;
  enabled: boolean;
  fileDescriptor: number;
  stack: string;
}

interface AppLogEntry {
  time: string;
  level: string;
  message: string;
}

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'ClashHarmonyIndex';
const APP_VERSION_NAME: string = 'v0.1.0';
const DELAY_TEST_TIMEOUT_MS: number = 4500;
const DELAY_TEST_URLS: string[] = [
  'https://cp.cloudflare.com/generate_204',
  'https://www.gstatic.com/generate_204',
  'http://connectivitycheck.platform.hicloud.com/generate_204'
];

const EMPTY_CORE_BRIDGE_STATE: CoreBridgeState = {
  running: false,
  tunFd: -1,
  nativeFd: -1,
  startCount: 0,
  stopCount: 0,
  controllerReady: false,
  controllerOnly: false,
  tunAttached: false,
  supportsControllerOnly: false,
  supportsTunAttach: false,
  realConnectionReady: false,
  configPath: '',
  coreMode: 'idle',
  adapterMode: 'unloaded',
  adapterKind: 'unknown',
  adapterInfo: '',
  adapterLoadError: '',
  adapterVersion: '',
  controllerVersion: '',
  version: '',
  lastError: '',
  packetsRead: 0,
  packetsWritten: 0,
  bytesRead: 0,
  bytesWritten: 0,
  readErrors: 0,
  writeErrors: 0,
  forwarderActive: false
};

@Entry
@Component
struct Index {
  @State private connectionView: ConnectionViewState = new ConnectionViewState();
  @State private trafficView: TrafficViewState = new TrafficViewState();
  @State private currentTab: string = 'home';
  @State private showSettings: boolean = false;
  @State private settingsPage: string = 'root';
  @State private toolPage: string = '';
  @State private appPreferences: AppPreferences = defaultAppPreferences();
  @State private sheetKind: string = 'import';
  @State private editorUid: string = '';
  @State private editorName: string = '';
  @State private editorText: string = '';
  @State private editorSaving: boolean = false;
  @State private advancedDiagnostics: boolean = false;
  @State private exitIp: string = '';
  @State private checkingExit: boolean = false;
  @State private profileState: ProfileState = createEmptyProfileState();
  @State private profileUpdate: ProfileUpdateViewState = new ProfileUpdateViewState();
  @State private profileMutationBusy: boolean = false;
  private summary: CoreSummary = CoreService.createSummary(createEmptyProfileState(), false);
  @State private vpnActionText: string = '连接';
  @State private showImportPanel: boolean = false;
  @State private importUrl: string = '';
  @State private importName: string = '';
  @State private statusMessage: string = '请先导入或启用一个配置';
  @State private runtimeConfigPath: string = '';
  @State private runtimeConfigInfo: string = '尚未生成运行配置';
  @State private proxyStatus: string = '当前配置尚未下载';
  @State private proxyNodes: ProxyNode[] = [];
  @State private proxySearchText: string = '';
  @State private proxyGroups: ProxyGroupInfo[] = [];
  @State private proxyGroupsSynced: boolean = false;
  @State private selectedProxyGroup: string = '';
  @State private pendingProxyGroup: string = '';
  @State private pendingProxyName: string = '';
  @State private isSpeedTesting: boolean = false;
  @State private syncingProxies: boolean = false;
  @State private speedTestProgress: string = '';
  @State private speedTestSummary: string = '';
  @State private diagSegment: string = '连接';
  @State private controllerStatus: ControllerStatus = {
    available: false,
    version: '',
    message: '尚未检查 controller',
    raw: ''
  };
  @State private coreBridgeState: CoreBridgeState = EMPTY_CORE_BRIDGE_STATE;
  @State private proxyMode: string = 'rule';
  @State private runtimeConnections: RuntimeConnectionRow[] = [];
  @State private rulesStatus: string = '尚未读取规则';
  @State private ruleLines: string[] = [];
  @State private dnsStatus: string = '尚未读取 DNS 配置';
  @State private dnsLines: string[] = [];
  @State private appLogs: AppLogEntry[] = [];
  @State private lifecycleLogs: string[] = [];
  @StorageProp('vpnAppForeground') @Watch('onAppVisibilityChanged') private appForeground: boolean = true;
  @StorageProp('vpnBackgroundStatus') private backgroundStatus: string = '后台任务尚未开启';
  @State private liveConnected: boolean = false;
  private liveUptime: string = '未连接';
  private liveDownloadSpeed: string = '0 KB/s';
  private liveUploadSpeed: string = '0 KB/s';
  private liveConnections: number = 0;
  @State private liveProfileName: string = '未选择配置';
  @State private liveProxyName: string = '未连接';
  @State private liveRuntimeConfigState: string = '未准备';
  @State private vpnTunnelActive: boolean = false;
  private homeLastDownloadTotal: number = 0;
  private homeLastUploadTotal: number = 0;
  private homeLastPollAt: number = 0;
  private homeTrafficBaselineReady: boolean = false;
  private connectedAt: number = 0;
  private lastToggleAt: number = 0;
  @State private toggling: boolean = false;
  private runtimeStream: ControllerStreamService = new ControllerStreamService();
  private eventsReady: Promise<boolean> = Promise.resolve(false);
  private sessionId: string = '';
  private latestEventSequence: number = 0;
  private startupStartedAt: number = 0;
  private homeRefreshGeneration: number = 0;
  private proxyHealthCheckedAt: number = 0;
  private proxyHealthOk: boolean = false;
  private proxyHealthDelay: number = 0;
  private proxyHealthNode: string = '';
  private proxyDelayCache: Record<string, ProxyDelayState> = {};

  aboutToAppear(): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'Index aboutToAppear, loading profiles');
    this.eventsReady = VpnRuntimeEvents.subscribe((event: VpnRuntimeEvent) => { this.onRuntimeEvent(event) });
    this.loadProfiles();
    this.loadAppPreferences();
    this.refreshLifecycleDiagnostics();
  }

  private refreshLifecycleDiagnostics(): void {
    this.lifecycleLogs = RuntimeDiagnostics.read(getContext(this) as common.Context);
  }

  private onAppVisibilityChanged(): void {
    if (!this.appForeground || this.toggling) { return }
    this.refreshLifecycleDiagnostics();
    this.stopHomeRefreshLoop();
    this.resumeRuntimeIfControllerAvailable();
  }

  aboutToDisappear(): void {
    VpnRuntimeEvents.unsubscribe();
    TrafficPollerService.stop();
    this.stopHomeRefreshLoop();
  }

  onBackPress(): boolean {
    if (this.showImportPanel) {
      this.showImportPanel = false;
      return true;
    }
    if (this.showSettings) {
      if (this.settingsPage !== 'root') {
        this.settingsPage = 'root';
      } else {
        this.showSettings = false;
      }
      return true;
    }
    if (this.toolPage.length > 0) {
      this.toolPage = '';
      return true;
    }
    return false;
  }

  private async loadAppPreferences(): Promise<void> {
    this.appPreferences = await AppPreferencesService.load(getContext(this) as common.Context);
    this.applyAppearance();
  }

  private applyAppearance(): void {
    const context = getContext(this) as common.Context;
    const mode: ConfigurationConstant.ColorMode = this.appPreferences.appearance === 'dark'
      ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK : this.appPreferences.appearance === 'light'
      ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    try {
      context.getApplicationContext().setColorMode(mode);
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'Unable to apply application color mode');
    }
  }

  private async persistPreferences(): Promise<void> {
    try {
      await AppPreferencesService.save(getContext(this) as common.Context, this.appPreferences);
      this.applyAppearance();
    } catch (err) {
      this.notify('设置保存失败，请重试');
    }
  }

  private notify(message: string): void {
    this.statusMessage = message;
    this.recordLog('info', message);
    try {
      promptAction.showToast({ message: message, duration: 2500 });
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'Unable to show toast');
    }
  }

  private async loadProfiles(): Promise<void> {
    const context = getContext(this) as common.Context;
    const state: ProfileState = await ProfileStore.load(context);
    this.runtimeConfigPath = RuntimeConfigService.getRuntimeConfigPath(context);
    this.applyProfileState(state);
    await this.refreshProxyNodes(state);
    await this.resumeRuntimeIfControllerAvailable();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'Profiles loaded: %{public}d items, currentUid=%{public}s',
      state.items.length, state.currentUid);
  }

  private connectionPhase(phase: string, message: string): void {
    this.connectionView.setPhase(phase, message);
    this.statusMessage = message;
  }

  private onRuntimeEvent(event: VpnRuntimeEvent): void {
    if (this.sessionId.length > 0 && event.sessionId !== this.sessionId) { return }
    if (this.sessionId.length === 0) { this.sessionId = event.sessionId; this.latestEventSequence = 0 }
    if (event.sequence <= this.latestEventSequence) { return }
    this.latestEventSequence = event.sequence;
    if (this.toggling && this.connectionView.phase === 'stopping' &&
      !['stopping', 'disconnected', 'error'].includes(event.phase)) { return }
    this.recordLog('info', 'VPN 阶段 ' + event.phase + ' · ' + event.elapsedMs + ' ms');
    const messages: Record<string, string> = {
      'creating': '正在建立 VPN', 'starting': '正在启动内核', 'verifying': '正在确认连接',
      'connected': '已连接', 'stopping': '正在断开 VPN', 'disconnected': '已断开', 'error': 'VPN 操作未完成'
    };
    this.connectionView.setPhase(event.phase === 'disconnected' ? 'idle' : event.phase, messages[event.phase]);
    if (event.phase === 'connected') {
      VpnBackgroundService.setEnabled(true);
      this.connectionView.connected = true;
      if (!this.toggling) {
        this.vpnTunnelActive = true;
        this.controllerStatus = { available: true, version: event.version, message: 'VPN 内核已就绪', raw: '' };
        this.connectedAt = this.connectedAt > 0 ? this.connectedAt : Date.now();
        this.summary = CoreService.createSummary(this.profileState, true);
        this.vpnActionText = '断开';
        this.statusMessage = 'VPN 已连接';
        this.syncHomeRuntimeFields();
        this.startRuntimePolling();
      }
    } else if (event.phase === 'disconnected') {
      VpnBackgroundService.setEnabled(false);
      this.connectionView.connected = false;
      if (!this.toggling) {
        this.stopHomeRefreshLoop();
        this.vpnTunnelActive = false;
        this.connectedAt = 0;
        this.clearProxyHealthState();
        this.summary = CoreService.createSummary(this.profileState, false);
        this.vpnActionText = '连接';
        this.runtimeConnections = [];
        this.statusMessage = 'VPN 已断开，可在日志查看后台运行记录';
        this.syncHomeRuntimeFields();
      }
    } else if (event.phase === 'error' && !this.toggling) {
      this.statusMessage = 'VPN 操作未完成，请查看诊断记录';
    }
  }

  private recordStartupStage(stage: string): void {
    const elapsed: number = Date.now() - this.startupStartedAt;
    this.recordLog('info', '连接耗时 · ' + stage + ' · ' + elapsed + ' ms');
    hilog.info(LOG_DOMAIN, LOG_TAG, 'connect timing stage=%{public}s elapsedMs=%{public}d', stage, elapsed);
  }

  private async refreshAfterConnection(group: string, node: string, version: string, generation: number): Promise<void> {
    try {
      await this.refreshControllerProxies();
      if (generation !== this.homeRefreshGeneration || !this.isRuntimeConnected()) { return }
      await this.restoreProxySelection(group, node);
      if (generation !== this.homeRefreshGeneration || !this.isRuntimeConnected()) { return }
      await this.verifySelectedProxyAfterConnection(version);
    } catch (err) {
      if (generation === this.homeRefreshGeneration && this.isRuntimeConnected()) {
        this.recordLog('warn', '连接已建立，附加节点检查未完成，可在代理页手动刷新');
      }
    }
  }

  private async toggleVpn(): Promise<void> {
    this.toggling = true;
    this.exitIp = '';
    hilog.info(LOG_DOMAIN, LOG_TAG, 'toggleVpn: start, state=%{public}s', this.summary.state);
    try {
      if (this.isRuntimeConnected()) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'toggleVpn: stopping');
        TrafficPollerService.stop();
        this.stopHomeRefreshLoop();
        this.connectionPhase('stopping', '正在断开 VPN');
        this.syncHomeRuntimeFields();
        const eventsAvailable: boolean = await this.eventsReady;
        const stopped: boolean = await VpnService.stopAndConfirm(this.sessionId, eventsAvailable);
        if (!stopped) {
          this.statusMessage = '断开请求超时或失败，请重试';
          this.recordLog('warn', this.statusMessage);
          this.startHomeRefreshLoop();
          this.syncHomeRuntimeFields();
          return;
        }
        this.connectedAt = 0;
        this.vpnTunnelActive = false;
        this.resetHomeTrafficBaseline();
        this.clearProxyHealthState();
        this.runtimeConnections = [];
        this.clearControllerProxyGroups();
        this.coreBridgeState = CoreBridgeService.markControllerReady(false, '');
        this.summary = CoreService.createSummary(this.profileState, false);
        this.vpnActionText = '连接';
        this.coreBridgeState = CoreBridgeService.getState();
        this.controllerStatus = { available: false, version: '', message: 'VPN 已停止', raw: '' };
        this.statusMessage = 'VPN 已停止';
        this.connectionView.setPhase('idle', '已断开');
        this.syncHomeRuntimeFields();
        this.recordLog('info', 'VPN 已停止，运行状态已清理');
        return;
      }

      if (this.profileState.currentUid.length === 0) {
        this.statusMessage = '请先在配置页导入并启用一个配置';
        this.currentTab = 'profiles';
        return;
      }

      this.startupStartedAt = Date.now();
      this.sessionId = Date.now().toString() + '-' + Math.random().toString(36).substring(2, 10);
      this.latestEventSequence = 0;
      this.connectionPhase('preparing', '正在准备配置');
      const context = getContext(this) as common.Context;
      const runtime: RuntimeConfigResult = await this.prepareRuntimeForConnection(context);
      if (!runtime.ok) {
        this.vpnTunnelActive = false;
        this.clearProxyHealthState();
        this.summary = CoreService.createSummary(this.profileState, false);
        this.statusMessage = runtime.message;
        hilog.error(LOG_DOMAIN, LOG_TAG, 'toggleVpn: runtime failed: %{public}s', runtime.message);
        return;
      }

      this.recordStartupStage('配置就绪');
      this.runtimeConfigPath = runtime.configPath;
      this.runtimeConfigInfo = `${runtime.profileName} · ${runtime.size}`;
      const restoreGroup: string = this.pendingProxyGroup.length > 0 ? this.pendingProxyGroup : this.selectedProxyGroup;
      const selectedNode: string = this.pendingProxyName.length > 0 ? this.pendingProxyName : this.getSelectedProxyNodeName();
      const restoreNode: string = selectedNode.length > 0 ? selectedNode : this.pendingProxyName;
      const localState: CoreBridgeState = CoreBridgeService.getState();
      if (localState.running || localState.coreMode === 'starting' || localState.coreMode === 'stopping') {
        this.connectionPhase('preparing', '正在切换至 VPN');
        this.coreBridgeState = await CoreBridgeService.stopCore();
        if (this.coreBridgeState.lastError.length > 0) {
          this.statusMessage = '无法释放本地测速核心：' + this.coreBridgeState.lastError;
          this.recordLog('warn', this.statusMessage);
          return;
        }
      }
      this.recordStartupStage('本地核心就绪');
      this.controllerStatus = { available: false, version: '', message: '正在启动 VPN', raw: '' };
      this.connectionPhase('creating', '正在建立 VPN');
      const eventsAvailable: boolean = await this.eventsReady;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'toggleVpn: calling VpnService.start');
      const started: boolean = await VpnService.start(runtime.configPath, this.sessionId);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'toggleVpn: VpnService.start returned %{public}s', started ? 'true' : 'false');

      if (!started) {
        this.vpnTunnelActive = false;
        this.clearProxyHealthState();
        this.summary = CoreService.createSummary(this.profileState, false);
        this.statusMessage = 'VPN 启动失败：模拟器可能不支持 VPN Extension，请使用真机';
        this.recordLog('warn', this.statusMessage);
        return;
      }

      this.recordStartupStage('系统接收启动请求');
      let controllerReady: ControllerStatus = { available: false, version: '', raw: '', message: '等待内核就绪' };
      let ready: boolean = false;
      let lifecycleFailed: boolean = false;
      if (eventsAvailable) {
        const event: VpnRuntimeEvent | undefined = await VpnRuntimeEvents.waitFor(
          this.sessionId, ['connected', 'error'], 20000);
        ready = event?.phase === 'connected';
        lifecycleFailed = event?.phase === 'error';
        controllerReady = {
          available: ready, version: event?.version ?? '', raw: '',
          message: ready ? 'VPN 内核已就绪' : '等待 VPN 内核就绪超时或失败'
        };
      }
      if (!ready && !lifecycleFailed) {
        // Dynamic common events may be delayed while the app is backgrounded.
        // A missing event alone must not tear down a working system tunnel.
        // These are bounded startup probes, never home polling.
        controllerReady = await MihomoControllerService.waitForVersion(10, 200);
        const tunReady: RuntimeTunStatus = controllerReady.available
          ? await this.waitForVpnTunReady(4, 150)
          : { ready: false, message: controllerReady.message, raw: '', enabled: false, fileDescriptor: 0, stack: '' };
        ready = tunReady.ready && await VpnService.hasSystemVpn() !== false;
      }
      this.controllerStatus = controllerReady;
      if (!ready) {
        this.stopHomeRefreshLoop();
        this.vpnTunnelActive = false;
        this.clearProxyHealthState();
        this.coreBridgeState = CoreBridgeService.markControllerReady(false, '');
        await VpnService.stop();
        this.summary = CoreService.createSummary(this.profileState, false);
        this.connectionPhase('error', '核心未响应：' + controllerReady.message);
        this.syncHomeRuntimeFields();
        this.recordLog('warn', this.statusMessage);
        return;
      }
      this.recordStartupStage('VPN 可用');
      this.coreBridgeState = CoreBridgeService.markControllerReady(true, controllerReady.version);
      this.vpnTunnelActive = true;
      this.summary = CoreService.createSummary(this.profileState, true);
      this.vpnActionText = '断开';
      this.statusMessage = `已连接 · ${controllerReady.version}`;
      this.connectedAt = Date.now();
      this.syncHomeRuntimeFields();
      this.startRuntimePolling();
      this.recordStartupStage('界面可操作');
      this.refreshAfterConnection(restoreGroup, restoreNode, controllerReady.version, this.homeRefreshGeneration);
      this.recordLog('info', `VPN 已连接，controller=${controllerReady.version}`);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'toggleVpn: connected');
    } catch (err) {
      TrafficPollerService.stop();
      this.stopHomeRefreshLoop();
      hilog.error(LOG_DOMAIN, LOG_TAG, 'toggleVpn: exception=%{public}s', JSON.stringify(err));
      this.statusMessage = '连接异常，请查看诊断页';
      this.vpnTunnelActive = false;
      this.resetHomeTrafficBaseline();
      this.clearProxyHealthState();
      this.summary = CoreService.createSummary(this.profileState, false);
      this.clearControllerProxyGroups();
      this.syncHomeRuntimeFields();
      this.recordLog('warn', this.statusMessage);
    } finally {
      this.toggling = false;
      if (this.connectionView.busy) {
        this.connectionView.setPhase(this.vpnTunnelActive ? 'connected' : 'error',
          this.vpnTunnelActive ? '已连接' : '连接未完成');
      }
      this.syncHomeRuntimeFields();
    }
  }

  private requestToggleVpn(): void {
    if (!this.isRuntimeConnected() && (this.profileUpdate.running || this.profileMutationBusy)) {
      this.notify('配置正在处理，请完成后连接');
      return;
    }
    if (this.toggling || this.connectionView.busy) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'toggleVpn skipped: already toggling');
      return;
    }
    const now: number = Date.now();
    if (now - this.lastToggleAt < 1500) {
      return;
    }
    this.lastToggleAt = now;
    this.toggleVpn();
  }

  private async prepareRuntimeForConnection(context: common.Context): Promise<RuntimeConfigResult> {
    let targetState: ProfileState = this.profileState;
    const current: ClashProfile | undefined = CoreService.getCurrentProfile(targetState);
    if (!current) {
      this.currentTab = 'profiles';
      return this.createRuntimeFailure('请先在配置页导入并启用一个配置');
    }

    if (current.type === 'remote' && current.filePath.length === 0) {
      this.statusMessage = '首次连接正在下载订阅...';
      const updateResult: SubscriptionUpdateResult = await SubscriptionService.updateProfile(context, current.uid);
      this.applyProfileState(updateResult.state);
      await this.refreshProxyNodes(updateResult.state);
      if (!updateResult.ok) {
        return this.createRuntimeFailure(updateResult.message);
      }
      targetState = updateResult.state;
    }

    let runtime: RuntimeConfigResult = await RuntimeConfigService.prepareCurrentProfile(context, targetState, this.normalizeProxyMode(this.proxyMode));
    if (!runtime.ok) {
      const latestCurrent: ClashProfile | undefined = CoreService.getCurrentProfile(targetState);
      if (latestCurrent && latestCurrent.type === 'remote') {
        this.statusMessage = '本地配置不可用，正在重新更新订阅...';
        const updateResult: SubscriptionUpdateResult = await SubscriptionService.updateProfile(context, latestCurrent.uid);
        this.applyProfileState(updateResult.state);
        await this.refreshProxyNodes(updateResult.state);
        if (!updateResult.ok) {
          return this.createRuntimeFailure(updateResult.message);
        }
        runtime = await RuntimeConfigService.prepareCurrentProfile(context, updateResult.state, this.normalizeProxyMode(this.proxyMode));
      }
    }

    return runtime;
  }

  private createRuntimeFailure(message: string): RuntimeConfigResult {
    return { ok: false, message: message, configPath: '', profileName: '', nodeCount: 0, size: '' };
  }

  private applyProfileState(state: ProfileState): void {
    const connected: boolean = this.isRuntimeConnected();
    const current: ClashProfile | undefined = CoreService.getCurrentProfile(state);
    this.profileState = state;
    const nextSummary: CoreSummary = CoreService.createSummary(state, connected);
    this.summary = connected ? {
      state: this.summary.state,
      mode: this.summary.mode,
      profileName: nextSummary.profileName,
      proxyName: this.summary.proxyName,
      uptime: this.summary.uptime,
      downloadSpeed: this.summary.downloadSpeed,
      uploadSpeed: this.summary.uploadSpeed,
      connections: this.summary.connections
    } : nextSummary;
    if (!connected) {
      this.statusMessage = current ? '配置已加载' : '请先导入或启用一个配置';
    }
    this.syncHomeRuntimeFields(state);
    this.liveProfileName = nextSummary.profileName;
    if (!connected) {
      this.liveProxyName = nextSummary.proxyName;
    }
  }

  private async resumeRuntimeIfControllerAvailable(): Promise<void> {
    if (this.toggling) { return }
    const generation: number = this.homeRefreshGeneration;
    const sessionId: string = this.sessionId;
    VpnControlChannel.send('status', this.sessionId);
    const status: ControllerStatus = await MihomoControllerService.waitForVersion(3, 150);
    if (generation !== this.homeRefreshGeneration || sessionId !== this.sessionId || this.toggling) { return }
    if (!status.available) {
      if (this.isRuntimeConnected()) {
        const systemVpn = await VpnService.hasSystemVpn();
        if (generation !== this.homeRefreshGeneration || sessionId !== this.sessionId || this.toggling) { return }
        if (systemVpn === false) {
          VpnBackgroundService.setEnabled(false);
          this.handleRuntimeUnavailable('系统 VPN 已断开，请查看后台运行记录');
          return;
        }
        this.statusMessage = '连接状态待确认，请查看后台运行记录或重新断开连接';
        this.recordLog('warn', this.statusMessage);
      }
      return;
    }

    this.controllerStatus = status;
    this.coreBridgeState = CoreBridgeService.markControllerReady(true, status.version);
    const systemVpn = await VpnService.hasSystemVpn();
    const tunReady: RuntimeTunStatus = await this.waitForVpnTunReady(1, 0);
    if (generation !== this.homeRefreshGeneration || sessionId !== this.sessionId || this.toggling) { return }
    if (!tunReady.ready || systemVpn === false) {
      VpnBackgroundService.setEnabled(false);
      this.vpnTunnelActive = false;
      this.connectedAt = 0;
      this.vpnActionText = '连接';
      this.summary = CoreService.createSummary(this.profileState, false);
      this.statusMessage = `controller 已连接：${status.version} · VPN 未连接`;
      await this.refreshControllerProxies();
      if (generation !== this.homeRefreshGeneration || sessionId !== this.sessionId || this.toggling) { return }
      await this.refreshConnections();
      if (generation !== this.homeRefreshGeneration || sessionId !== this.sessionId || this.toggling) { return }
      this.syncHomeRuntimeFields();
      return;
    }

    this.vpnTunnelActive = true;
    VpnBackgroundService.setEnabled(true);
    if (this.connectedAt <= 0) {
      this.connectedAt = Date.now();
    }
    this.vpnActionText = '断开';
    await this.refreshControllerProxies();
    if (generation !== this.homeRefreshGeneration || sessionId !== this.sessionId || this.toggling) { return }
    this.summary = this.createLiveSummary({
      downloadSpeed: this.summary.downloadSpeed,
      uploadSpeed: this.summary.uploadSpeed,
      totalDownload: 0,
      totalUpload: 0,
      activeConnections: this.summary.connections,
      memoryUsage: '',
      uptimeSeconds: 0,
      mode: this.proxyMode,
      controllerAvailable: true,
      message: 'controller 正常'
    });
    this.statusMessage = `已连接 · ${status.version}`;
    this.startRuntimePolling();
    await this.refreshConnections();
    if (generation !== this.homeRefreshGeneration || sessionId !== this.sessionId || this.toggling) { return }
    this.syncHomeRuntimeFields();
  }

  private async addRemoteProfile(): Promise<void> {
    if (this.profileUpdate.running || this.profileMutationBusy || this.toggling) { return }
    const url: string = this.importUrl.trim();
    if (url.length === 0) {
      this.statusMessage = '订阅 URL 不能为空';
      return;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      this.statusMessage = '请输入 http 或 https 开头的订阅 URL';
      return;
    }
    this.profileMutationBusy = true;
    try {
      const name: string = this.importName.trim().length > 0 ? this.importName.trim() : this.createProfileNameFromUrl(url);
      const context = getContext(this) as common.Context;
      const added: ClashProfile = createRemoteProfile(name, url);
      const next: ProfileState = await ProfileStore.addRemote(context, added);
      this.importUrl = '';
      this.importName = '';
      this.showImportPanel = false;
      this.currentTab = 'profiles';
      this.applyProfileState(next);
      await this.runProfileUpdates([added.uid]);
    } catch (err) { this.notify('添加配置失败，请稍后重试') }
    finally { this.profileMutationBusy = false }
  }

  private async importFromClipboard(): Promise<void> {
    if (this.profileUpdate.running || this.profileMutationBusy || this.toggling) { return }
    this.profileMutationBusy = true;
    try {
      this.statusMessage = '正在读取剪贴板...';
      const context = getContext(this) as common.Context;
      const result: ClipboardImportResult = await ClipboardImportService.importProfile(context);
      this.applyProfileState(result.state);
      await this.refreshProxyNodes(result.state);
      this.statusMessage = result.message;
      this.syncHomeRuntimeFields();
      this.recordLog(result.ok ? 'info' : 'warn', result.message);
    } catch (err) { this.notify('剪贴板导入失败，请重试') }
    finally { this.profileMutationBusy = false }
  }

  private async importLocalFile(): Promise<void> {
    if (this.profileUpdate.running || this.profileMutationBusy || this.toggling) { return }
    this.profileMutationBusy = true;
    try {
      this.statusMessage = '请选择本地 YAML 或订阅文本文件...';
      const context = getContext(this) as common.Context;
      const result: FileImportResult = await LocalFileImportService.pickAndImport(context);
      this.applyProfileState(result.state);
      await this.refreshProxyNodes(result.state);
      this.statusMessage = result.message;
      this.syncHomeRuntimeFields();
      this.recordLog(result.ok ? 'info' : 'warn', result.message);
    } catch (err) { this.notify('文件导入失败，请重试') }
    finally { this.profileMutationBusy = false }
  }

  private async activateProfile(uid: string): Promise<void> {
    if (this.profileUpdate.running || this.profileMutationBusy || this.toggling) { return }
    this.profileMutationBusy = true;
    try {
      const context = getContext(this) as common.Context;
      const next: ProfileState = await ProfileStore.activate(context, uid);
      this.applyProfileState(next);
      await this.refreshProxyNodes(next);
      this.statusMessage = '已切换当前配置';
      this.syncHomeRuntimeFields();
      this.recordLog('info', this.statusMessage);
    } catch (err) { this.notify('切换配置失败，请重试') }
    finally { this.profileMutationBusy = false }
  }

  private async removeProfile(uid: string): Promise<void> {
    if (this.profileUpdate.running || this.profileMutationBusy || this.toggling) { return }
    this.profileMutationBusy = true;
    try {
      const context = getContext(this) as common.Context;
      const next: ProfileState = await ProfileStore.remove(context, uid);
      this.applyProfileState(next);
      await this.refreshProxyNodes(next);
      this.statusMessage = '配置已删除';
      this.syncHomeRuntimeFields();
      this.recordLog('info', this.statusMessage);
    } catch (err) { this.notify('删除配置失败，请重试') }
    finally { this.profileMutationBusy = false }
  }

  private async updateProfile(uid: string): Promise<void> {
    if (this.profileMutationBusy || this.toggling) { return }
    await this.runProfileUpdates([uid]);
  }

  private async updateAllProfiles(): Promise<void> {
    if (this.profileUpdate.running || this.profileMutationBusy || this.toggling) { return }
    const remoteUids: string[] = [];
    for (let index = 0; index < this.profileState.items.length; index++) {
      if (this.profileState.items[index].type === 'remote') {
        remoteUids.push(this.profileState.items[index].uid);
      }
    }
    if (remoteUids.length === 0) {
      this.statusMessage = '没有可更新的远程订阅';
      return;
    }
    await this.runProfileUpdates(remoteUids, true);
  }

  private async runProfileUpdates(uids: string[], batch: boolean = false): Promise<void> {
    if (this.editorSaving || this.toggling) { return }
    if (!this.profileUpdate.begin(uids, batch)) { return }
    let latestState: ProfileState = this.profileState;
    let message: string = '更新未完成，请重试';
    try {
      const context = getContext(this) as common.Context;
      for (const uid of uids) {
        const item: ClashProfile | undefined = latestState.items.find((profile: ClashProfile) => profile.uid === uid);
        this.profileUpdate.downloading(uid, item?.name ?? '配置');
        this.statusMessage = this.profileUpdate.message;
        try {
          const result: SubscriptionUpdateResult = await SubscriptionService.updateProfile(context, uid);
          latestState = result.state;
          this.applyProfileState(latestState);
          this.profileUpdate.complete(uid, result.ok, result.message);
        } catch (err) {
          this.profileUpdate.complete(uid, false, '更新失败，请检查网络或存储后重试');
        }
      }
      const failed: number = uids.length - this.profileUpdate.succeeded;
      message = batch ? '更新完成：' + this.profileUpdate.succeeded + '/' + uids.length + ' 个订阅成功' :
        this.profileUpdate.messageFor(uids[0]);
      const currentUpdated: boolean = this.profileUpdate.results.some((result) => result.uid === latestState.currentUid && result.ok);
      if (currentUpdated) {
        this.profileUpdate.activeUid = '';
        this.profileUpdate.message = '正在准备运行配置';
        const runtime: RuntimeConfigResult = await RuntimeConfigService.prepareCurrentProfile(context, latestState);
        if (runtime.ok) {
          this.runtimeConfigPath = runtime.configPath;
          this.runtimeConfigInfo = `${runtime.profileName} · ${runtime.size}`;
        } else { this.profileUpdate.failed = true; message += '；' + runtime.message }
      }
      // Updating a file must not replace the active core's proxy selection.
      if (!this.isRuntimeConnected()) { await this.refreshProxyNodes(latestState) }
      if (currentUpdated && this.isRuntimeConnected()) { message += '，重新连接后生效' }
      this.syncHomeRuntimeFields();
      this.recordLog(failed === 0 ? 'info' : 'warn', message);
    } catch (err) {
      this.profileUpdate.failed = true;
      message = this.profileUpdate.succeeded > 0 ? '订阅已保存，运行配置准备未完成，请重试' : '更新失败，请稍后重试';
      this.recordLog('warn', message);
    } finally {
      this.profileUpdate.finish(message);
      this.statusMessage = message;
      try { promptAction.showToast({ message: message, duration: 2500 }) } catch (err) {}
    }
  }

  private async refreshControllerStatus(): Promise<void> {
    if (this.toggling) { return }
    const generation: number = this.homeRefreshGeneration;
    const sessionId: string = this.sessionId;
    const status: ControllerStatus = await MihomoControllerService.checkVersion();
    if (generation !== this.homeRefreshGeneration || sessionId !== this.sessionId || this.toggling) { return }
    this.controllerStatus = status;
    this.coreBridgeState = CoreBridgeService.markControllerReady(status.available, status.version);
    this.statusMessage = status.available ? `controller 已连接：${status.version}` : status.message;
    this.syncHomeRuntimeFields();
    this.recordLog(status.available ? 'info' : 'warn', this.statusMessage);
    if (status.available) {
      await this.refreshControllerProxies();
      const tunReady: RuntimeTunStatus = await this.waitForVpnTunReady(1, 0);
      if (generation !== this.homeRefreshGeneration || sessionId !== this.sessionId || this.toggling) { return }
      if (tunReady.ready) {
        this.vpnTunnelActive = true;
        this.connectedAt = Date.now();
        this.vpnActionText = '断开';
        this.startRuntimePolling();
      } else {
        this.vpnTunnelActive = false;
        this.connectedAt = 0;
        this.vpnActionText = '连接';
        this.summary = CoreService.createSummary(this.profileState, false);
        this.statusMessage = `controller 已连接：${status.version} · VPN 未连接`;
      }
      await this.refreshConnections();
      this.syncHomeRuntimeFields();
    }
  }

  private async syncProxyView(): Promise<void> {
    if (this.syncingProxies || this.isSpeedTesting) { return }
    this.syncingProxies = true;
    try { await this.refreshControllerProxies() }
    catch (err) { this.notify('代理同步失败，请稍后重试') }
    finally { this.syncingProxies = false }
  }

  private async ensureControllerReadyForProxyActions(action: string): Promise<boolean> {
    let status: ControllerStatus = await MihomoControllerService.checkVersion();
    if (status.available) {
      this.controllerStatus = status;
      this.coreBridgeState = CoreBridgeService.markControllerReady(true, status.version);
      if (!this.proxyGroupsSynced) {
        await this.refreshControllerProxies();
      }
      return true;
    }

    if (this.isRuntimeConnected()) {
      this.statusMessage = `${action}：等待 VPN 核心响应...`;
      status = await MihomoControllerService.waitForVersion(6, 500);
      this.controllerStatus = status;
      this.coreBridgeState = CoreBridgeService.markControllerReady(status.available, status.version);
      if (status.available) {
        await this.refreshControllerProxies();
        return true;
      }
      this.statusMessage = `${action}失败：${status.message}`;
      this.recordLog('warn', this.statusMessage);
      return false;
    }

    const context = getContext(this) as common.Context;
    this.statusMessage = `${action}：正在准备运行配置...`;
    const runtime: RuntimeConfigResult = await this.prepareRuntimeForConnection(context);
    if (!runtime.ok) {
      this.statusMessage = runtime.message;
      this.recordLog('warn', runtime.message);
      return false;
    }

    this.runtimeConfigPath = runtime.configPath;
    this.runtimeConfigInfo = `${runtime.profileName} · ${runtime.size}`;
    this.statusMessage = `${action}：正在启动测速核心...`;
    this.syncHomeRuntimeFields();
    this.coreBridgeState = await CoreBridgeService.startCore(runtime.configPath);
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'ensureControllerReady: action=%{public}s startCore running=%{public}s controllerOnly=%{public}s mode=%{public}s adapter=%{public}s kind=%{public}s supportsControllerOnly=%{public}s version=%{public}s error=%{public}s',
      action,
      this.coreBridgeState.running ? 'true' : 'false',
      this.coreBridgeState.controllerOnly ? 'true' : 'false',
      this.coreBridgeState.coreMode,
      this.coreBridgeState.adapterMode,
      this.coreBridgeState.adapterKind,
      this.coreBridgeState.supportsControllerOnly ? 'true' : 'false',
      this.coreBridgeState.adapterVersion,
      this.coreBridgeState.lastError);
    if (!this.coreBridgeState.running || !this.coreBridgeState.controllerOnly) {
      const reason: string = this.coreBridgeState.lastError.length > 0
        ? this.coreBridgeState.lastError
        : '当前 native 核心不支持 controller-only';
      this.statusMessage = `${action}失败：${reason}`;
      this.recordLog('warn', this.statusMessage);
      return false;
    }

    status = await MihomoControllerService.waitForVersion(10, 500);
    this.controllerStatus = status;
    this.coreBridgeState = CoreBridgeService.markControllerReady(status.available, status.version);
    this.syncHomeRuntimeFields();
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'ensureControllerReady: action=%{public}s waitForVersion available=%{public}s version=%{public}s message=%{public}s nativeRunning=%{public}s controllerOnly=%{public}s error=%{public}s',
      action,
      status.available ? 'true' : 'false',
      status.version,
      status.message,
      this.coreBridgeState.running ? 'true' : 'false',
      this.coreBridgeState.controllerOnly ? 'true' : 'false',
      this.coreBridgeState.lastError);
    if (!status.available) {
      const nativeDetail: string = this.coreBridgeState.lastError.length > 0 ? `；native=${this.coreBridgeState.lastError}` : '';
      this.statusMessage = `${action}失败：${status.message}${nativeDetail}`;
      this.recordLog('warn', this.statusMessage);
      return false;
    }

    await MihomoControllerService.setMode(this.normalizeProxyMode(this.proxyMode));
    await this.refreshControllerProxies();
    this.statusMessage = `${action}：controller 已就绪`;
    this.recordLog('info', this.statusMessage);
    return true;
  }

  private async handleSectionAction(action: string): Promise<void> {
    if (action === '全量更新') {
      await this.updateAllProfiles();
    } else if (action === '查看') {
      this.currentTab = 'diagnostics';
    } else if (action === '关闭全部') {
      await this.closeAllControllerConnections();
    } else if (action === '导出') {
      await this.exportAppLogs();
    }
  }

  private async refreshProxyNodes(state?: ProfileState): Promise<void> {
    const context = getContext(this) as common.Context;
    const targetState: ProfileState = state ? state : this.profileState;
    const parsed: ParsedConfigSummary = await ClashConfigParserService.parseCurrentProfile(context, targetState);
    this.proxyStatus = parsed.message;
    const nodes: ProxyNode[] = [];
    for (let index = 0; index < parsed.nodes.length; index++) {
      nodes.push(this.mapParsedProxyNode(parsed.nodes[index], index));
    }
    this.proxyNodes = nodes;
    this.clearControllerProxyGroups();
  }

  private mapParsedProxyNode(node: ParsedProxyNode, index: number): ProxyNode {
    const delayState: ProxyDelayState = this.getCachedProxyDelayState(node.name);
    return {
      name: node.name,
      meta: `${node.type}${node.udp ? ' · UDP' : ''}`,
      delay: delayState.delay,
      selected: index === 0,
      status: delayState.status,
      server: node.server,
      port: node.port
    };
  }

  private async changeProxyMode(mode: 'rule' | 'global' | 'direct'): Promise<void> {
    if (this.proxyMode === mode) {
      this.statusMessage = `当前已是${this.modeLabel(mode)}模式`;
      return;
    }

    this.proxyMode = mode;
    const controllerCanApply: boolean = this.controllerStatus.available || this.coreBridgeState.controllerReady || this.proxyGroupsSynced;
    if (!controllerCanApply) {
      this.statusMessage = `已切换到${this.modeLabel(mode)}模式，连接或测速启动核心后生效`;
      this.syncHomeRuntimeFields();
      this.recordLog('info', this.statusMessage);
      return;
    }

    const ok: boolean = await MihomoControllerService.setMode(mode);
    this.statusMessage = ok ? `已切换到${this.modeLabel(mode)}模式` : '模式切换失败，controller 未响应';
    if (ok) {
      this.summary = {
        state: this.isRuntimeConnected() ? 'running' : 'stopped',
        mode: mode,
        profileName: this.currentProfileDisplayName(),
        proxyName: this.summary.proxyName,
        uptime: this.summary.uptime,
        downloadSpeed: this.summary.downloadSpeed,
        uploadSpeed: this.summary.uploadSpeed,
        connections: this.summary.connections
      };
      this.syncHomeRuntimeFields();
    }
    this.recordLog(ok ? 'info' : 'warn', this.statusMessage);
  }

  private async refreshControllerProxies(): Promise<void> {
    const generation: number = this.homeRefreshGeneration;
    const previousSelectedGroup: string = this.selectedProxyGroup;
    const result: ControllerTextResult = await MihomoControllerService.getProxies();
    if (generation !== this.homeRefreshGeneration) { return }
    if (!result.ok) {
      this.proxyStatus = result.message;
      return;
    }

    const groups: ProxyGroupInfo[] = MihomoControllerService.parseProxyGroups(result.raw);
    this.proxyGroups = groups;
    if (groups.length === 0) {
      this.proxyStatus = 'controller 已连接，但未返回可选择策略组';
      return;
    }

    this.selectedProxyGroup = this.resolvePreferredProxyGroupName(groups, previousSelectedGroup);
    this.proxyGroupsSynced = true;
    this.applySelectedProxyGroup();
  }

  private clearControllerProxyGroups(): void {
    this.proxyGroups = [];
    this.proxyGroupsSynced = false;
    this.selectedProxyGroup = '';
  }

  private applySelectedProxyGroup(): void {
    const group: ProxyGroupInfo | undefined = this.findSelectedProxyGroup();
    if (!group) {
      return;
    }

    const nodes: ProxyNode[] = [];
    for (let index = 0; index < group.all.length; index++) {
      const name: string = group.all[index];
      const delayState: ProxyDelayState = this.getCachedProxyDelayState(name);
      nodes.push({
        name: name,
        meta: `${group.name} · ${group.type}`,
        delay: delayState.delay,
        selected: name === group.now,
        status: delayState.status
      });
    }
    this.proxyNodes = nodes;
    this.proxyStatus = `${group.name} · 当前 ${group.now.length > 0 ? group.now : '未选择'} · ${group.all.length} 个节点`;
    this.syncHomeRuntimeFields();
  }

  private findSelectedProxyGroup(): ProxyGroupInfo | undefined {
    for (let index = 0; index < this.proxyGroups.length; index++) {
      if (this.proxyGroups[index].name === this.selectedProxyGroup) {
        return this.proxyGroups[index];
      }
    }
    return this.proxyGroups.length > 0 ? this.proxyGroups[0] : undefined;
  }

  private resolvePreferredProxyGroupName(groups: ProxyGroupInfo[], previousSelectedGroup: string): string {
    if (groups.length === 0) {
      return '';
    }

    if (previousSelectedGroup.length > 0 && this.hasProxyGroup(groups, previousSelectedGroup)) {
      return previousSelectedGroup;
    }

    if (this.pendingProxyGroup.length > 0 && this.hasProxyGroup(groups, this.pendingProxyGroup)) {
      return this.pendingProxyGroup;
    }

    if (this.proxyMode === 'global' && this.hasProxyGroup(groups, 'GLOBAL')) {
      return 'GLOBAL';
    }

    const trafficGroup: string = this.findRuleTrafficProxyGroupName(groups);
    if (trafficGroup.length > 0) {
      return trafficGroup;
    }

    if (previousSelectedGroup.length > 0 && this.hasProxyGroup(groups, previousSelectedGroup)) {
      return previousSelectedGroup;
    }
    return groups[0].name;
  }

  private findRuleTrafficProxyGroupName(groups: ProxyGroupInfo[]): string {
    const preferredNames: string[] = ['Proxy', 'PROXY', '🚀 节点选择', '节点选择', '自动选择', 'Auto'];
    for (let preferredIndex = 0; preferredIndex < preferredNames.length; preferredIndex++) {
      if (this.hasProxyGroup(groups, preferredNames[preferredIndex])) {
        return preferredNames[preferredIndex];
      }
    }

    for (let index = 0; index < groups.length; index++) {
      if (groups[index].name !== 'GLOBAL') {
        return groups[index].name;
      }
    }
    return '';
  }

  private hasProxyGroup(groups: ProxyGroupInfo[], groupName: string): boolean {
    for (let index = 0; index < groups.length; index++) {
      if (groups[index].name === groupName) {
        return true;
      }
    }
    return false;
  }

  private findRuntimeProxyGroup(): ProxyGroupInfo | undefined {
    if (this.proxyMode === 'global') {
      const globalGroup: ProxyGroupInfo | undefined = this.findProxyGroupByName('GLOBAL');
      if (globalGroup) {
        return globalGroup;
      }
    }

    const trafficGroupName: string = this.findRuleTrafficProxyGroupName(this.proxyGroups);
    if (trafficGroupName.length > 0) {
      const trafficGroup: ProxyGroupInfo | undefined = this.findProxyGroupByName(trafficGroupName);
      if (trafficGroup) {
        return trafficGroup;
      }
    }
    return this.findSelectedProxyGroup();
  }

  private findProxyGroupByName(groupName: string): ProxyGroupInfo | undefined {
    for (let index = 0; index < this.proxyGroups.length; index++) {
      if (this.proxyGroups[index].name === groupName) {
        return this.proxyGroups[index];
      }
    }
    return undefined;
  }

  private selectProxyGroup(groupName: string): void {
    this.selectedProxyGroup = groupName;
    this.applySelectedProxyGroup();
  }

  private async selectProxyNode(node: ProxyNode): Promise<void> {
    this.exitIp = '';
    const previousName: string = this.getSelectedProxyNodeName();
    this.statusMessage = `正在切换节点：${node.name}`;
    let group: ProxyGroupInfo | undefined = this.findSelectedProxyGroup();
    if (group) {
      this.pendingProxyGroup = group.name;
    }
    this.pendingProxyName = node.name;
    this.markSelectedProxyNode(node.name);
    this.syncHomeRuntimeFields();
    await this.waitForUiUpdate(0);

    if (!group) {
      const ready: boolean = await this.ensureControllerReadyForProxyActions('切换节点');
      if (!ready) {
        return;
      }
      group = this.findSelectedProxyGroup();
      if (!group) {
        this.statusMessage = '当前没有可选择的策略组';
        this.recordLog('warn', this.statusMessage);
        return;
      }
    }

    const ok: boolean = await MihomoControllerService.selectProxy(group.name, node.name);
    if (!ok) {
      if (previousName.length > 0 && previousName !== node.name) {
        this.markSelectedProxyNode(previousName);
      }
      this.pendingProxyName = previousName;
      this.pendingProxyGroup = group.name;
      this.statusMessage = `切换节点失败：${group.name} -> ${node.name}`;
      this.recordLog('warn', this.statusMessage);
      return;
    }

    this.statusMessage = `已切换 ${group.name} -> ${node.name}`;
    this.pendingProxyGroup = group.name;
    this.pendingProxyName = node.name;
    this.markSelectedProxyNode(node.name);
    this.recordLog('info', this.statusMessage);
    await this.refreshControllerProxies();
    this.summary = this.createLiveSummary({
      downloadSpeed: this.summary.downloadSpeed,
      uploadSpeed: this.summary.uploadSpeed,
      totalDownload: 0,
      totalUpload: 0,
      activeConnections: this.summary.connections,
      memoryUsage: '',
      uptimeSeconds: 0,
      mode: this.proxyMode,
      controllerAvailable: this.controllerStatus.available,
      message: this.controllerStatus.message
    });
    this.syncHomeRuntimeFields();
  }

  private markSelectedProxyNode(name: string): void {
    const nodes: ProxyNode[] = [];
    for (let index = 0; index < this.proxyNodes.length; index++) {
      const node: ProxyNode = this.proxyNodes[index];
      nodes.push({
        name: node.name,
        meta: node.meta,
        delay: node.delay,
        selected: node.name === name,
        status: node.status,
        server: node.server,
        port: node.port
      });
    }
    this.proxyNodes = nodes;
  }

  private getSelectedProxyNodeName(): string {
    for (let index = 0; index < this.proxyNodes.length; index++) {
      if (this.proxyNodes[index].selected) {
        return this.proxyNodes[index].name;
      }
    }
    return '';
  }

  private async restoreProxySelection(groupName: string, proxyName: string): Promise<void> {
    if (groupName.length === 0 || proxyName.length === 0) {
      return;
    }
    const generation: number = this.homeRefreshGeneration;
    const ok: boolean = await MihomoControllerService.selectProxy(groupName, proxyName);
    if (generation !== this.homeRefreshGeneration || !this.isRuntimeConnected()) { return }
    if (!ok) {
      this.recordLog('warn', `连接后恢复节点失败：${groupName} -> ${proxyName}`);
      return;
    }
    this.pendingProxyGroup = groupName;
    this.pendingProxyName = proxyName;
    this.selectedProxyGroup = groupName;
    this.markSelectedProxyNode(proxyName);
    await this.refreshControllerProxies();
    this.recordLog('info', `连接后已恢复节点：${groupName} -> ${proxyName}`);
  }

  private getVisibleProxyNodes(): ProxyNode[] {
    const query: string = this.proxySearchText.trim().toLowerCase();
    const result: ProxyNode[] = [];
    for (let index = 0; index < this.proxyNodes.length; index++) {
      const node: ProxyNode = this.proxyNodes[index];
      const haystack: string = `${node.name} ${node.meta}`.toLowerCase();
      if (query.length === 0 || haystack.indexOf(query) >= 0) {
        result.push(node);
      }
    }
    if (this.appPreferences.proxySort === 'name') {
      result.sort((left: ProxyNode, right: ProxyNode) => left.name.localeCompare(right.name));
    } else if (this.appPreferences.proxySort === 'delay') {
      result.sort((left: ProxyNode, right: ProxyNode) => {
        const leftDelay: number = this.parseDelayText(left.delay);
        const rightDelay: number = this.parseDelayText(right.delay);
        return (leftDelay > 0 ? leftDelay : Number.MAX_SAFE_INTEGER) -
          (rightDelay > 0 ? rightDelay : Number.MAX_SAFE_INTEGER);
      });
    }
    return result;
  }

  private getVisibleProxyNodeIndexes(): number[] {
    const query: string = this.proxySearchText.trim().toLowerCase();
    const indexes: number[] = [];
    for (let index = 0; index < this.proxyNodes.length; index++) {
      if (query.length === 0) {
        indexes.push(index);
        continue;
      }
      const node: ProxyNode = this.proxyNodes[index];
      const haystack: string = `${node.name} ${node.meta}`.toLowerCase();
      if (haystack.indexOf(query) >= 0) {
        indexes.push(index);
      }
    }
    return indexes;
  }

  private getAllProxyNodeIndexes(): number[] {
    const indexes: number[] = [];
    for (let index = 0; index < this.proxyNodes.length; index++) {
      if (this.isRejectPolicy(this.proxyNodes[index].name)) {
        continue;
      }
      indexes.push(index);
    }
    return indexes;
  }

  private startRuntimePolling(): void {
    TrafficPollerService.stop();
    this.startHomeRefreshLoop();
  }

  private startHomeRefreshLoop(): void {
    if (!this.isRuntimeConnected()) { return }
    this.runtimeStream.start((raw: string) => { this.applyConnectionsSnapshot(raw) }, () => {
      this.reconcileRuntimeAfterStreamFailure();
    });
  }

  private stopHomeRefreshLoop(): void {
    this.homeRefreshGeneration++;
    this.runtimeStream.stop();
  }

  private async reconcileRuntimeAfterStreamFailure(): Promise<void> {
    const generation: number = this.homeRefreshGeneration;
    const status: ControllerStatus = await MihomoControllerService.checkVersion();
    if (generation !== this.homeRefreshGeneration || this.toggling) { return }
    if (!status.available) {
      this.statusMessage = '实时通道中断，连接状态待确认；回到前台后重新核对';
      this.recordLog('warn', this.statusMessage);
    } else {
      this.statusMessage = '实时数据暂不可用，VPN 连接保持，可手动刷新';
      this.recordLog('warn', this.statusMessage);
    }
  }

  private applyConnectionsSnapshot(raw: string): void {
    if (!this.isRuntimeConnected()) { return }
    try {
      const data = JSON.parse(raw) as Record<string, Object>;
      const totalDownload: number = typeof data['downloadTotal'] === 'number' ? data['downloadTotal'] as number : 0;
      const totalUpload: number = typeof data['uploadTotal'] === 'number' ? data['uploadTotal'] as number : 0;
      const connections: Object[] = data['connections'] as Object[];
      if (!Number.isFinite(totalDownload) || !Number.isFinite(totalUpload) || !Array.isArray(connections)) { return }
      VpnBackgroundService.updateTraffic(totalDownload, totalUpload);
      const now: number = Date.now();
      const elapsed: number = (now - this.homeLastPollAt) / 1000;
      let down: number = 0;
      let up: number = 0;
      if (this.homeTrafficBaselineReady && elapsed > 0) {
        down = Math.max(0, totalDownload - this.homeLastDownloadTotal) / elapsed;
        up = Math.max(0, totalUpload - this.homeLastUploadTotal) / elapsed;
      }
      this.homeLastPollAt = now;
      this.homeLastDownloadTotal = totalDownload;
      this.homeLastUploadTotal = totalUpload;
      this.homeTrafficBaselineReady = true;
      this.liveDownloadSpeed = this.formatSpeedValue(down);
      this.liveUploadSpeed = this.formatSpeedValue(up);
      this.liveConnections = connections.length;
      this.liveUptime = this.formatRuntimeUptime();
      this.trafficView.downloadSpeed = this.liveDownloadSpeed;
      this.trafficView.uploadSpeed = this.liveUploadSpeed;
      this.trafficView.connections = this.liveConnections;
      this.trafficView.uptime = this.liveUptime;
      this.trafficView.downloadHistory = this.trafficView.downloadHistory.slice(1).concat([down]);
      this.trafficView.uploadHistory = this.trafficView.uploadHistory.slice(1).concat([up]);
      this.summary.downloadSpeed = this.liveDownloadSpeed;
      this.summary.uploadSpeed = this.liveUploadSpeed;
      this.summary.connections = this.liveConnections;
      this.summary.uptime = this.liveUptime;
      if (this.currentTab === 'diagnostics' && this.toolPage === '连接') {
        this.runtimeConnections = this.mapControllerConnections(MihomoControllerService.parseConnections(raw));
      }
    } catch (err) {}
  }

  private handleRuntimeUnavailable(message: string): void {
    TrafficPollerService.stop();
    this.stopHomeRefreshLoop();
    this.connectedAt = 0;
    this.vpnTunnelActive = false;
    this.resetHomeTrafficBaseline();
    this.clearProxyHealthState();
    this.runtimeConnections = [];
    this.controllerStatus = { available: false, version: '', message: message, raw: '' };
    this.coreBridgeState = CoreBridgeService.markControllerReady(false, '');
    this.summary = CoreService.createSummary(this.profileState, false);
    this.vpnActionText = '连接';
    this.statusMessage = message.length > 0 ? message : 'controller 已断开';
    this.syncHomeRuntimeFields();
  }

  private createLiveSummary(snapshot: TrafficSnapshot): CoreSummary {
    const current: ClashProfile | undefined = CoreService.getCurrentProfile(this.profileState);
    return {
      state: 'running',
      mode: this.normalizeProxyMode(snapshot.mode),
      profileName: current ? current.name : this.currentProfileDisplayName(),
      proxyName: this.currentProxyLabel(),
      uptime: this.formatRuntimeUptime(),
      downloadSpeed: snapshot.downloadSpeed,
      uploadSpeed: snapshot.uploadSpeed,
      connections: snapshot.activeConnections
    };
  }

  private mapPollerConnections(connections: PollerConnectionInfo[]): RuntimeConnectionRow[] {
    const result: RuntimeConnectionRow[] = [];
    const limit: number = connections.length > 50 ? 50 : connections.length;
    for (let index = 0; index < limit; index++) {
      const item: PollerConnectionInfo = connections[index];
      const target: string = item.metadata.host.length > 0
        ? item.metadata.host
        : `${item.metadata.destIP}${item.metadata.type.length > 0 ? ` · ${item.metadata.type}` : ''}`;
      result.push({
        id: item.id,
        target: target.length > 0 ? target : 'unknown',
        chain: item.chains.join(' / '),
        rule: item.rule.length > 0 ? item.rule : 'MATCH',
        upload: this.formatBytes(item.upload),
        download: this.formatBytes(item.download)
      });
    }
    return result;
  }

  private mapControllerConnections(connections: ControllerConnectionInfo[]): RuntimeConnectionRow[] {
    const result: RuntimeConnectionRow[] = [];
    const limit: number = connections.length > 50 ? 50 : connections.length;
    for (let index = 0; index < limit; index++) {
      const item: ControllerConnectionInfo = connections[index];
      const target: string = item.metadata.host.length > 0
        ? item.metadata.host
        : `${item.metadata.destinationIP}:${item.metadata.destinationPort}`;
      result.push({
        id: item.id,
        target: target.length > 0 ? target : 'unknown',
        chain: item.chains.join(' / '),
        rule: item.rule.length > 0 ? item.rule : 'MATCH',
        upload: this.formatBytes(item.upload),
        download: this.formatBytes(item.download)
      });
    }
    return result;
  }

  private async refreshConnections(): Promise<void> {
    const generation: number = this.homeRefreshGeneration;
    const result: ControllerTextResult = await MihomoControllerService.getConnections();
    if (generation !== this.homeRefreshGeneration) { return }
    if (!result.ok) {
      this.recordLog('warn', result.message);
      return;
    }
    const connections: ControllerConnectionInfo[] = MihomoControllerService.parseConnections(result.raw);
    this.runtimeConnections = this.mapControllerConnections(connections);
    this.summary = {
      state: this.isRuntimeConnected() ? 'running' : 'stopped',
      mode: this.summary.mode,
      profileName: this.currentProfileDisplayName(),
      proxyName: this.summary.proxyName,
      uptime: this.summary.uptime,
      downloadSpeed: this.summary.downloadSpeed,
      uploadSpeed: this.summary.uploadSpeed,
      connections: connections.length
    };
    this.syncHomeRuntimeFields();
  }

  private async closeAllControllerConnections(): Promise<void> {
    const ok: boolean = await MihomoControllerService.closeAllConnections();
    if (ok) {
      this.runtimeConnections = [];
      this.statusMessage = '已关闭全部 controller 连接';
    } else {
      this.statusMessage = '关闭连接失败，controller 未响应';
    }
    this.recordLog(ok ? 'info' : 'warn', this.statusMessage);
  }

  private async refreshRules(): Promise<void> {
    const result: ControllerTextResult = await MihomoControllerService.getRules();
    if (!result.ok) {
      this.rulesStatus = result.message;
      this.ruleLines = [];
      this.recordLog('warn', result.message);
      return;
    }
    this.ruleLines = this.pickJsonArrayPreview(result.raw, 'rules', 40);
    this.rulesStatus = `已同步 ${this.ruleLines.length} 条规则预览`;
    this.recordLog('info', this.rulesStatus);
  }

  private async refreshDnsConfig(): Promise<void> {
    const result: ControllerTextResult = await MihomoControllerService.getConfig();
    if (!result.ok) {
      this.dnsStatus = result.message;
      this.dnsLines = [];
      this.recordLog('warn', result.message);
      return;
    }
    this.dnsLines = this.pickJsonObjectPreview(result.raw, 'dns', 40);
    this.dnsStatus = this.dnsLines.length > 0 ? 'DNS 配置已同步' : '当前配置未返回 DNS 字段';
    this.recordLog('info', this.dnsStatus);
  }

  private pickJsonArrayPreview(raw: string, key: string, limit: number): string[] {
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const array = parsed[key] as Object[];
      if (!Array.isArray(array)) {
        return [];
      }
      const result: string[] = [];
      const count: number = array.length > limit ? limit : array.length;
      for (let index = 0; index < count; index++) {
        result.push(String(array[index]));
      }
      return result;
    } catch (err) {
      return raw.split('\n').slice(0, limit);
    }
  }

  private pickJsonObjectPreview(raw: string, key: string, limit: number): string[] {
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const value: Object | undefined = parsed[key];
      if (!value) {
        return [];
      }
      return JSON.stringify(value, null, 2).split('\n').slice(0, limit);
    } catch (err) {
      return raw.split('\n').slice(0, limit);
    }
  }

  private recordLog(level: string, message: string): void {
    const next: AppLogEntry[] = [{
      time: this.formatLogTime(new Date()),
      level: level,
      message: message
    }];
    for (let index = 0; index < this.appLogs.length && index < 49; index++) {
      next.push(this.appLogs[index]);
    }
    this.appLogs = next;
  }

  private formatLogTime(date: Date): string {
    const hours: string = date.getHours() < 10 ? `0${date.getHours()}` : `${date.getHours()}`;
    const minutes: string = date.getMinutes() < 10 ? `0${date.getMinutes()}` : `${date.getMinutes()}`;
    const seconds: string = date.getSeconds() < 10 ? `0${date.getSeconds()}` : `${date.getSeconds()}`;
    return `${hours}:${minutes}:${seconds}`;
  }

  private normalizeProxyMode(mode: string): 'rule' | 'global' | 'direct' {
    if (mode === 'global' || mode === 'direct') {
      return mode;
    }
    return 'rule';
  }

  private modeLabel(mode: string): string {
    if (mode === 'global') {
      return '全局';
    }
    if (mode === 'direct') {
      return '直连';
    }
    return '规则';
  }

  private formatGroupDelay(group: ProxyGroupInfo, name: string): string {
    return this.getCachedProxyDelayState(name).delay;
  }

  private currentProxyLabel(): string {
    if (!this.isRuntimeConnected()) {
      return '未连接';
    }
    const group: ProxyGroupInfo | undefined = this.findRuntimeProxyGroup();
    if (group && group.now.length > 0) {
      return `${group.name} -> ${group.now}`;
    }
    if (this.pendingProxyGroup.length > 0 && this.pendingProxyName.length > 0) {
      return `${this.pendingProxyGroup} -> ${this.pendingProxyName}`;
    }
    return this.isRuntimeConnected() ? '等待策略组同步' : '未连接';
  }

  private isRuntimeConnected(): boolean {
    return this.vpnTunnelActive;
  }

  private currentProfileDisplayName(state?: ProfileState): string {
    const targetState: ProfileState = state ? state : this.profileState;
    const current: ClashProfile | undefined = CoreService.getCurrentProfile(targetState);
    if (current) {
      return current.name;
    }
    if (this.summary.profileName.length > 0 && this.summary.profileName !== '未选择配置') {
      return this.summary.profileName;
    }
    if (this.runtimeConfigInfo.length > 0 && this.runtimeConfigInfo !== '尚未生成运行配置') {
      const separator: number = this.runtimeConfigInfo.indexOf(' · ');
      return separator > 0 ? this.runtimeConfigInfo.substring(0, separator) : this.runtimeConfigInfo;
    }
    return this.isRuntimeConnected() ? '当前运行配置' : '未选择配置';
  }

  private runtimeConfigDisplayState(): string {
    if (this.runtimeConfigInfo !== '尚未生成运行配置') {
      return '已准备';
    }
    return this.isRuntimeConnected() ? '已加载' : '未准备';
  }

  private syncHomeRuntimeFields(state?: ProfileState): void {
    const connected: boolean = this.isRuntimeConnected();
    this.liveConnected = connected;
    this.liveUptime = connected ? this.summary.uptime : '未连接';
    this.liveDownloadSpeed = connected ? this.summary.downloadSpeed : '0 KB/s';
    this.liveUploadSpeed = connected ? this.summary.uploadSpeed : '0 KB/s';
    this.liveConnections = connected ? this.summary.connections : 0;
    this.liveProfileName = this.currentProfileDisplayName(state);
    this.liveProxyName = this.currentProxyLabel();
    this.liveRuntimeConfigState = this.runtimeConfigDisplayState();
    this.connectionView.connected = connected;
    this.connectionView.profileName = this.liveProfileName;
    if (!this.toggling && this.connectionView.phase !== 'error') {
      this.connectionView.setPhase(connected ? 'connected' : 'idle', connected ? '已连接' : '未连接');
    }
    this.trafficView.downloadSpeed = this.liveDownloadSpeed;
    this.trafficView.uploadSpeed = this.liveUploadSpeed;
    this.trafficView.connections = this.liveConnections;
    this.trafficView.uptime = connected ? this.liveUptime : '--:--:--';
  }

  private parseControllerMode(raw: string): 'rule' | 'global' | 'direct' {
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const mode = parsed['mode'];
      return typeof mode === 'string' ? this.normalizeProxyMode(mode as string) : 'rule';
    } catch (err) {
      return 'rule';
    }
  }


  private resetHomeTrafficBaseline(): void {
    this.homeLastDownloadTotal = 0;
    this.homeLastUploadTotal = 0;
    this.homeLastPollAt = 0;
    this.homeTrafficBaselineReady = false;
  }



  private formatRuntimeUptime(): string {
    if (this.connectedAt <= 0) {
      return '刚刚启动';
    }
    const seconds: number = Math.floor((Date.now() - this.connectedAt) / 1000);
    return CoreService.formatUptime(seconds);
  }

  private formatBytes(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  }

  private formatSpeedValue(bytesPerSecond: number): string {
    if (bytesPerSecond < 1024) {
      return `${bytesPerSecond.toFixed(1)} B/s`;
    }
    if (bytesPerSecond < 1024 * 1024) {
      return `${(bytesPerSecond / 1024).toFixed(1)} KB/s`;
    }
    return `${(bytesPerSecond / 1024 / 1024).toFixed(1)} MB/s`;
  }

  build() {
    Column() {
      this.AppBar()
      if (this.showSettings) {
        this.SettingsScreen()
      } else {
        if (this.currentTab === 'home') {
          this.HomeScreen()
        } else if (this.currentTab === 'proxies') {
          this.ProxyScreen()
        } else if (this.currentTab === 'profiles') {
          this.ProfileScreen()
        } else {
          this.DiagnosticsScreen()
        }
        this.BottomNavigation()
      }
    }
    .width('100%').height('100%').backgroundColor(AppTheme.background)
    .bindSheet($$this.showImportPanel, this.SheetContent(), {
      height: SheetSize.LARGE,
      showClose: true,
      dragBar: true,
      backgroundColor: AppTheme.background,
      title: { title: this.sheetKind === 'editor' ? '编辑配置' : '添加配置' }
    })
  }

  @Builder
  private Icon(source: Resource, size: number = 22, color: ResourceColor = AppTheme.text) {
    Image(source).width(size).height(size).fillColor(color).accessibilityLevel('no')
  }

  @Builder
  private AppBar() {
    Row({ space: 12 }) {
      if (this.showSettings || this.toolPage.length > 0) {
        Button({ type: ButtonType.Circle }) {
          this.Icon($r('app.media.ui_back'))
        }
        .width(44).height(44).backgroundColor(AppTheme.variant)
        .accessibilityText('返回').onClick(() => { this.onBackPress() })
      }
      Text(this.pageTitle()).fontSize(24).fontWeight(FontWeight.Medium).fontColor(AppTheme.text)
        .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (!this.showSettings && this.currentTab === 'profiles') {
        Button({ type: ButtonType.Circle }) {
          if (this.profileUpdate.running) {
            LoadingProgress().width(22).height(22).color(AppTheme.primary)
          } else {
            this.Icon($r('app.media.ui_refresh'), 22, AppTheme.muted)
          }
        }.width(48).height(48).backgroundColor(Color.Transparent)
          .enabled(!this.toggling && !this.profileUpdate.running && !this.profileMutationBusy &&
            this.profileState.items.some((item: ClashProfile) => item.type === 'remote'))
          .accessibilityText(this.profileUpdate.running ? '正在更新配置' : '更新全部订阅')
          .onClick(() => { this.updateAllProfiles() })
        Button({ type: ButtonType.Circle }) {
          this.Icon($r('app.media.ui_plus'), 23, AppTheme.primary)
        }.width(48).height(48).backgroundColor(AppTheme.primaryContainer)
          .enabled(!this.toggling && !this.profileUpdate.running && !this.profileMutationBusy).accessibilityText('添加配置')
          .onClick(() => { this.sheetKind = 'import'; this.showImportPanel = true })
      } else if (!this.showSettings) {
        Button({ type: ButtonType.Circle }) {
          this.Icon($r('app.media.ui_settings'), 23, AppTheme.muted)
        }
        .width(48).height(48).backgroundColor(Color.Transparent)
        .accessibilityText('设置').onClick(() => { this.openSettings('root') })
      }
    }
    .width('100%').constraintSize({ maxWidth: AppTheme.contentMaxWidth }).height(64)
      .padding({ left: AppTheme.gutter, right: AppTheme.gutter })
  }

  @Builder
  private BottomNavigation() {
    AppNavigationBar({
      selected: this.currentTab,
      updating: this.profileUpdate.running,
      onNavigate: (key: string) => { this.currentTab = key; this.toolPage = '' }
    })
  }

  @Builder
  private Pill(text: string, color: ResourceColor, bg: ResourceColor) {
    Text(text).fontSize(11).fontWeight(FontWeight.Medium).fontColor(color)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 }).backgroundColor(bg).borderRadius(20)
  }

  @Builder
  private SectionTitle(title: string, action: string) {
    Row() {
      Text(title).fontSize(16).fontWeight(FontWeight.Bold).fontColor(AppTheme.text).layoutWeight(1)
      if (action.length > 0) {
        Button(action).height(44).fontSize(13).fontColor(AppTheme.primary)
          .backgroundColor(Color.Transparent).padding({ left: 12, right: 0 })
          .onClick(() => { this.handleSectionAction(action) })
      }
    }.width('100%')
  }

  @Builder
  private Metric(label: string, value: string) {
    Column({ space: 6 }) {
      Text(label).fontSize(12).fontColor(AppTheme.muted)
      Text(value).fontSize(18).fontWeight(FontWeight.Bold).fontColor(AppTheme.text).maxLines(1)
    }.layoutWeight(1).padding(12).backgroundColor(AppTheme.variant).borderRadius(18)
  }

  @Builder
  private ModeButton(text: string, active: boolean) {
    Text(text).height(44).width('100%').textAlign(TextAlign.Center).fontSize(13)
      .fontWeight(active ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(active ? AppTheme.onPrimaryContainer : AppTheme.muted)
      .backgroundColor(active ? AppTheme.primaryContainer : Color.Transparent).borderRadius(20)
  }

  @Builder
  private ProxyModeOption(text: string, mode: 'rule' | 'global' | 'direct') {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 6 }) {
        this.Icon(mode === 'rule' ? $r('app.media.ui_route') : mode === 'global' ? $r('app.media.ui_globe') : $r('app.media.ui_shield'),
          17, this.proxyMode === mode ? AppTheme.onPrimaryContainer : AppTheme.muted)
        Text(text).fontSize(14).fontWeight(FontWeight.Medium)
      }
    }
    .height(44).layoutWeight(1).borderRadius(14)
    .fontColor(this.proxyMode === mode ? AppTheme.onPrimaryContainer : AppTheme.muted)
    .backgroundColor(this.proxyMode === mode ? AppTheme.primaryContainer : Color.Transparent)
    .onClick(() => { this.changeProxyMode(mode) })
  }

  @Builder
  private GroupButton(text: string, active: boolean) {
    Text(text).fontSize(13).fontWeight(active ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(active ? AppTheme.onPrimaryContainer : AppTheme.muted).maxLines(1)
      .padding({ left: 16, right: 16, top: 13, bottom: 13 })
      .backgroundColor(active ? AppTheme.primaryContainer : AppTheme.surface).borderRadius(22)
  }

  @Builder
  private InfoRow(label: string, value: string) {
    Row({ space: 12 }) {
      Text(label).fontSize(13).fontColor(AppTheme.muted)
      Text(value).fontSize(14).fontColor(AppTheme.text).layoutWeight(1)
        .textAlign(TextAlign.End).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width('100%').constraintSize({ minHeight: 40 })
  }

  @Builder
  private StatusLine(title: string, subtitle: string, status: string) {
    Row({ space: 12 }) {
      Column({ space: 5 }) {
        Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.text)
        Text(subtitle).fontSize(12).fontColor(AppTheme.muted).maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      this.Pill(status, status === '正常' ? AppTheme.success : AppTheme.primary,
        status === '正常' ? AppTheme.successContainer : AppTheme.primaryContainer)
    }.width('100%').padding(14).backgroundColor(AppTheme.variant).borderRadius(18)
  }

  @Builder
  private EmptyState(title: string, subtitle: string) {
    Column({ space: 12 }) {
      this.Icon($r('app.media.ui_folder'), 36, AppTheme.primary)
      Text(title).fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppTheme.text)
      Text(subtitle).fontSize(13).fontColor(AppTheme.muted).textAlign(TextAlign.Center)
    }.width('100%').padding({ top: 40, bottom: 40, left: 24, right: 24 })
      .backgroundColor(AppTheme.surface).borderRadius(28)
  }

  @Builder
  private LogLine(time: string, level: string, message: string) {
    Column({ space: 7 }) {
      Row({ space: 8 }) {
        Text(time).fontSize(11).fontColor(AppTheme.muted)
        this.Pill(level, level === 'warn' ? AppTheme.warning : AppTheme.primary, AppTheme.variant)
      }.width('100%')
      Text(message).fontSize(12).fontColor(AppTheme.text).width('100%')
    }.padding(12).alignItems(HorizontalAlign.Start)
  }

  @Builder
  private Notice(message: string) {
    Row({ space: 10 }) {
      this.Icon($r('app.media.ui_info'), 18, AppTheme.muted)
      Text(message).fontSize(12).fontColor(AppTheme.muted).layoutWeight(1).maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width('100%').padding(14).backgroundColor(AppTheme.variant).borderRadius(18)
  }

  @Builder
  private HomeScreen() {
    Scroll() {
      Column({ space: 12 }) {
        this.HomeStatusCard()
        this.HomeSpeedCard()
        this.HomeModeCard()
        this.HomeCurrentRouteCard()
        this.HomeRecentStatusCard()
      }.width('100%').constraintSize({ maxWidth: AppTheme.contentMaxWidth })
        .padding({ left: AppTheme.gutter, right: AppTheme.gutter, top: 8, bottom: 16 })
    }.layoutWeight(1).scrollBar(BarState.Off).width('100%')
  }

  @Builder
  private HomeStatusCard() {
    HomeConnectionCard({
      connection: this.connectionView, traffic: this.trafficView,
      exitIp: this.exitIp, checkingExit: this.checkingExit,
      startBlocked: this.profileUpdate.running || this.profileMutationBusy,
      onToggle: () => { this.requestToggleVpn() },
      onCheckExit: () => { this.checkExitIp() }
    })
  }

  @Builder
  private HomeSpeedCard() {
    HomeTrafficCard({ traffic: this.trafficView })
  }

  @Builder
  private HomeModeCard() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        this.Icon($r('app.media.ui_route'), 18, AppTheme.muted)
        Text('出站模式').fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.text)
      }.width('100%')
      Row({ space: 4 }) {
        this.ProxyModeOption('规则', 'rule')
        this.ProxyModeOption('全局', 'global')
        this.ProxyModeOption('直连', 'direct')
      }.width('100%').padding(3).backgroundColor(AppTheme.variant).borderRadius(17)
    }.width('100%').padding(16).backgroundColor(AppTheme.surface).borderRadius(AppTheme.cardRadius)
  }



  @Builder
  private HomeCurrentRouteCard() {
    Row({ space: 12 }) {
      Button({ type: ButtonType.Normal }) {
        Column({ space: 10 }) {
          Row() {
            this.Icon($r('app.media.ui_file'), 20, AppTheme.primary)
            Blank()
            this.Icon($r('app.media.ui_chevron'), 16, AppTheme.muted)
          }.width('100%')
          Column({ space: 5 }) {
            Text('当前配置').fontSize(12).fontColor(AppTheme.muted)
            Text(this.liveProfileName).fontSize(15).fontWeight(FontWeight.Medium).fontColor(AppTheme.text)
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).constraintSize({ minHeight: 116 }).padding(16)
        .backgroundColor(AppTheme.surface).borderRadius(AppTheme.rowRadius)
        .accessibilityText('当前配置，' + this.liveProfileName + '，点击切换')
        .onClick(() => { this.currentTab = 'profiles' })
      Button({ type: ButtonType.Normal }) {
        Column({ space: 10 }) {
          Row() {
            this.Icon($r('app.media.ui_globe'), 20, AppTheme.primary)
            Blank()
            this.Icon($r('app.media.ui_chevron'), 16, AppTheme.muted)
          }.width('100%')
          Column({ space: 5 }) {
            Text('代理策略').fontSize(12).fontColor(AppTheme.muted)
            Text(this.liveProxyName).fontSize(15).fontWeight(FontWeight.Medium).fontColor(AppTheme.text)
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).constraintSize({ minHeight: 116 }).padding(16)
        .backgroundColor(AppTheme.surface).borderRadius(AppTheme.rowRadius)
        .accessibilityText('代理策略，' + this.liveProxyName + '，点击切换')
        .onClick(() => { this.currentTab = 'proxies' })
    }.width('100%').alignItems(VerticalAlign.Top)
  }

  @Builder
  private HomeRecentStatusCard() {
    Text(this.profileUpdate.running ? this.profileUpdate.message : this.statusMessage)
      .fontSize(12).fontColor(AppTheme.muted).width('100%').maxLines(3)
      .textOverflow({ overflow: TextOverflow.Ellipsis }).padding({ left: 4, right: 4, top: 4, bottom: 8 })
  }

  @Builder
  private ProxyScreen() {
    Column({ space: 12 }) {
      Row({ space: 4 }) {
        this.ProxyModeOption('规则', 'rule')
        this.ProxyModeOption('全局', 'global')
        this.ProxyModeOption('直连', 'direct')
      }.padding(3).backgroundColor(AppTheme.variant).borderRadius(17).margin({ left: AppTheme.gutter, right: AppTheme.gutter })
      if (this.proxyGroups.length > 0) {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.proxyGroups, (group: ProxyGroupInfo) => {
              Button({ type: ButtonType.Normal }) {
                this.GroupButton(group.name, this.selectedProxyGroup === group.name)
              }.padding(0).backgroundColor(Color.Transparent).borderRadius(22)
                .onClick(() => { this.selectProxyGroup(group.name) })
            }, (group: ProxyGroupInfo) => group.name)
          }.padding({ left: AppTheme.gutter, right: AppTheme.gutter })
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).height(46)
      }
      Row({ space: 8 }) {
        this.Icon($r('app.media.ui_search'), 20, AppTheme.muted)
        TextInput({ placeholder: '搜索节点、地区或提供者', text: this.proxySearchText })
          .layoutWeight(1).height(46).fontSize(14).backgroundColor(Color.Transparent).fontColor(AppTheme.text)
          .padding(0).onChange((value: string) => { this.proxySearchText = value })
      }.padding({ left: 16, right: 16 }).backgroundColor(AppTheme.variant).borderRadius(24)
        .margin({ left: AppTheme.gutter, right: AppTheme.gutter })
      Row({ space: 8 }) {
        Text('节点 ' + this.getVisibleProxyNodes().length + ' / ' + this.proxyNodes.length)
          .fontSize(13).fontColor(AppTheme.muted).layoutWeight(1)
        Button({ type: ButtonType.Circle }) {
          this.Icon($r('app.media.ui_sort'), 22, AppTheme.primary)
        }.width(44).height(44).backgroundColor(AppTheme.surface).accessibilityText('排序与显示')
          .bindMenu(this.proxyDisplayMenu())
        Button({ type: ButtonType.Circle }) {
          if (this.syncingProxies) {
            LoadingProgress().width(21).height(21).color(AppTheme.primary)
          } else {
            this.Icon($r('app.media.ui_refresh'), 21, AppTheme.primary)
          }
        }.width(48).height(48).backgroundColor(AppTheme.surface)
          .enabled(!this.syncingProxies && !this.isSpeedTesting).accessibilityText('同步代理')
          .onClick(() => { this.syncProxyView() })
        Button({ type: ButtonType.Circle }) {
          if (this.isSpeedTesting) {
            LoadingProgress().width(22).height(22).color(AppTheme.onPrimary)
          } else {
            this.Icon($r('app.media.ui_gauge'), 22, AppTheme.onPrimary)
          }
        }.width(48).height(48).padding(0).backgroundColor(AppTheme.primary)
          .accessibilityText(this.isSpeedTesting ? '测速中' : '测速')
          .enabled(!this.isSpeedTesting).onClick(async () => { await this.runRealSpeedTest() })
      }.margin({ left: AppTheme.gutter, right: AppTheme.gutter })
      if (this.speedTestProgress.length > 0) {
        Text(this.speedTestProgress).fontSize(12).fontColor(AppTheme.primary).width('100%')
          .padding({ left: 24, right: 24 })
      }
      if (this.getVisibleProxyNodes().length === 0) {
        Column() {
          this.EmptyState(this.proxyNodes.length > 0 ? '没有匹配的节点' : '还没有节点',
            this.proxyNodes.length > 0 ? '试试其他名称或地区关键词' : '前往配置页添加订阅，再来选择代理')
        }.layoutWeight(1).padding({ left: AppTheme.gutter, right: AppTheme.gutter })
      } else {
        Grid() {
          ForEach(this.getVisibleProxyNodes(), (node: ProxyNode) => {
            GridItem() { this.ProxyNodeRow(node) }
          }, (node: ProxyNode) => node.name + '-' + node.delay + '-' + node.status + '-' + node.selected)
        }.columnsTemplate(this.appPreferences.proxyColumns === 2 ? '1fr 1fr' : '1fr')
          .columnsGap(10).rowsGap(10).layoutWeight(1).width('100%')
          .padding({ left: AppTheme.gutter, right: AppTheme.gutter, bottom: 12 }).scrollBar(BarState.Off)
      }
      Text(this.statusMessage).fontSize(11).fontColor(AppTheme.muted).maxLines(2)
        .padding({ left: 24, right: 24 }).width('100%')
    }.layoutWeight(1).width('100%').constraintSize({ maxWidth: AppTheme.contentMaxWidth }).padding({ top: 8 })
  }

  @Builder
  private ProxyNodeRow(node: ProxyNode) {
    Button({ type: ButtonType.Normal }) {
      if (this.appPreferences.proxyColumns === 2) {
        Column({ space: 6 }) {
          Row({ space: 6 }) {
            Text(node.name).fontSize(14).fontWeight(FontWeight.Medium).fontColor(AppTheme.text)
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            if (node.selected) { this.Icon($r('app.media.ui_check'), 16, AppTheme.primary) }
          }.width('100%').constraintSize({ minHeight: 36 }).alignItems(VerticalAlign.Top)
          Text(this.isRejectPolicy(node.name) ? '拒绝连接策略' : node.meta).fontSize(12).fontColor(AppTheme.muted)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          Text(this.isRejectPolicy(node.name) ? '拦截' : node.delay).fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor(this.nodeDelayColor(node)).width('100%')
        }.width('100%').alignItems(HorizontalAlign.Start)
      } else {
        Row({ space: 12 }) {
          this.Icon(node.selected ? $r('app.media.ui_check') : $r('app.media.ui_globe'), 20,
            node.selected ? AppTheme.primary : AppTheme.muted)
          Column({ space: 5 }) {
            Text(node.name).fontSize(15).fontWeight(FontWeight.Medium).fontColor(AppTheme.text).maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
            Text(this.isRejectPolicy(node.name) ? '拒绝连接策略' : node.meta).fontSize(12).fontColor(AppTheme.muted)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Text(this.isRejectPolicy(node.name) ? '拦截' : node.delay).fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor(this.nodeDelayColor(node)).maxLines(1)
        }.width('100%')
      }
    }.width('100%').constraintSize({ minHeight: this.appPreferences.proxyColumns === 2 ? 112 : 76 }).padding(12)
      .backgroundColor(node.selected ? AppTheme.selectedSurface : AppTheme.surface).borderRadius(16)
      .border({ width: 1, color: node.selected ? AppTheme.primary : AppTheme.outline })
      .accessibilityText(node.name + (node.selected ? '，已选中' : '') + '，' + node.delay)
      .onClick(() => { this.selectProxyNode(node) })
  }

  @Builder
  private ProfileScreen() {
    Scroll() {
      Column({ space: 12 }) {
        Row() {
          Text('订阅与本地配置').fontSize(13).fontColor(AppTheme.muted).layoutWeight(1)
          Text(this.profileState.items.length + ' 个配置').fontSize(12).fontColor(AppTheme.muted)
        }.width('100%').padding({ left: 4, right: 4, top: 4, bottom: 4 })
        if (this.profileUpdate.message.length > 0) {
          ProfileUpdateBanner({ update: this.profileUpdate })
        }
        if (this.profileState.items.length === 0) {
          this.EmptyState('添加你的第一个配置', '点击右上角 +，从订阅链接、剪贴板或本地文件导入')
        } else {
          ForEach(this.profileState.items, (item: ClashProfile) => {
            this.ProfileRow(item)
          }, (item: ClashProfile) => item.uid + '-' + item.updatedAt + '-' + item.name + '-' + this.profileState.currentUid)
          Text('点击名称切换配置；流量与到期信息随订阅更新').fontSize(12).fontColor(AppTheme.muted)
            .width('100%').padding({ left: 4, right: 4, top: 4 })
        }
      }.width('100%').constraintSize({ maxWidth: AppTheme.contentMaxWidth })
        .padding({ left: AppTheme.gutter, right: AppTheme.gutter, top: 8, bottom: 24 })
    }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Off)
  }

  @Builder
  private ProfileRow(item: ClashProfile) {
    ProfileListCard({
      profile: item, current: item.uid === this.profileState.currentUid,
      mutating: this.profileMutationBusy || this.toggling, update: this.profileUpdate, menu: this.profileMenu(item),
      onActivate: () => { this.activateProfile(item.uid) },
      onUpdate: () => { this.updateProfile(item.uid) },
      onEdit: () => { this.openProfileEditor(item) }
    })
  }

  @Builder
  private SheetContent() {
    if (this.sheetKind === 'editor') {
      this.EditorPanel()
    } else {
      this.ImportPanel()
    }
  }

  @Builder
  private ImportPanel() {
    Scroll() {
      Column({ space: 20 }) {
        Text('从链接导入').fontSize(20).fontWeight(FontWeight.Bold).fontColor(AppTheme.text).width('100%')
        Column({ space: 8 }) {
          Text('配置名称').fontSize(13).fontColor(AppTheme.muted).width('100%')
          TextInput({ placeholder: '可选，例如：我的订阅', text: this.importName }).height(52).fontColor(AppTheme.text)
            .backgroundColor(AppTheme.variant).borderRadius(18)
            .onChange((value: string) => { this.importName = value })
        }
        Column({ space: 8 }) {
          Text('订阅链接').fontSize(13).fontColor(AppTheme.muted).width('100%')
          TextInput({ placeholder: 'https://', text: this.importUrl }).height(52).type(InputType.URL).fontColor(AppTheme.text)
            .backgroundColor(AppTheme.variant).borderRadius(18)
            .onChange((value: string) => { this.importUrl = value })
        }
        Button({ type: ButtonType.Normal }) {
          Row({ space: 8 }) {
            if (this.profileMutationBusy) { LoadingProgress().width(18).height(18).color(AppTheme.onPrimary) }
            Text(this.profileMutationBusy ? '正在添加…' : '导入订阅').fontSize(15)
          }
        }.width('100%').height(52).backgroundColor(AppTheme.primary).fontColor(AppTheme.onPrimary).borderRadius(26)
          .enabled(this.importUrl.trim().length > 0 && !this.profileMutationBusy && !this.profileUpdate.running)
          .onClick(() => { this.addRemoteProfile() })
        Row({ space: 12 }) {
          Column() {
            PasteButton({ buttonType: ButtonType.Capsule }).width('100%').height(50)
              .backgroundColor(AppTheme.primaryContainer).fontColor(AppTheme.onPrimaryContainer)
              .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
                if (result === PasteButtonOnClickResult.SUCCESS) {
                  this.showImportPanel = false;
                  this.importFromClipboard();
                } else {
                  this.notify('未获得本次粘贴授权，请重试或使用文件导入');
                }
              })
          }.layoutWeight(1)
          Button('选择文件').layoutWeight(1).height(50).backgroundColor(AppTheme.variant)
            .enabled(!this.profileMutationBusy && !this.profileUpdate.running)
            .fontColor(AppTheme.text).onClick(() => { this.showImportPanel = false; this.importLocalFile() })
        }
        this.Notice('支持 Clash / Mihomo YAML 配置及兼容订阅链接')
      }.padding(24)
    }.width('100%').height('100%')
  }

  @Builder
  private EditorPanel() {
    Column({ space: 12 }) {
      TextInput({ placeholder: '配置名称', text: this.editorName }).height(48)
        .fontColor(AppTheme.text).backgroundColor(AppTheme.variant)
        .onChange((value: string) => { this.editorName = value })
      Text('编辑本地内容。远程订阅再次更新时会覆盖此处修改。')
        .fontSize(12).fontColor(AppTheme.muted).width('100%')
      TextArea({ text: this.editorText }).layoutWeight(1).fontSize(12).fontFamily('monospace')
        .fontColor(AppTheme.text).backgroundColor(AppTheme.surface).borderRadius(18)
        .onChange((value: string) => { this.editorText = value })
      Button(this.editorSaving ? '保存中…' : '保存配置').width('100%').height(50)
        .backgroundColor(AppTheme.primary).fontColor(AppTheme.onPrimary).enabled(!this.editorSaving)
        .onClick(() => { this.saveProfileEditor() })
    }.width('100%').height('100%').padding(24)
  }

  @Builder
  private ToolRow(title: string, subtitle: string, icon: Resource, action: () => void) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 14 }) {
        Column() { this.Icon(icon, 22, AppTheme.primary) }
          .width(44).height(44).justifyContent(FlexAlign.Center).backgroundColor(AppTheme.variant).borderRadius(15)
        Column({ space: 5 }) {
          Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(AppTheme.text)
          Text(subtitle).fontSize(12).fontColor(AppTheme.muted).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        this.Icon($r('app.media.ui_chevron'), 15, AppTheme.muted)
      }.width('100%')
    }.width('100%').constraintSize({ minHeight: 80 }).padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor(AppTheme.surface).borderRadius(20).onClick(() => { action() })
  }

  @Builder
  private DiagnosticsScreen() {
    if (this.toolPage.length === 0) {
      Scroll() {
        Column({ space: 10 }) {
          this.ToolRow('实时连接', '查看流量去向与当前连接', $r('app.media.ui_activity'), () => { this.openTool('连接') })
          this.ToolRow('运行日志', '查看连接、订阅与测速记录', $r('app.media.ui_file'), () => { this.openTool('日志') })
          this.ToolRow('分流规则', '查看当前配置的匹配规则', $r('app.media.ui_route'), () => { this.openTool('规则') })
          this.ToolRow('DNS', '查看当前 DNS 配置', $r('app.media.ui_globe'), () => { this.openTool('DNS') })
          Text('偏好与管理').fontSize(13).fontColor(AppTheme.muted).width('100%').margin({ top: 16, bottom: 4 })
          this.ToolRow('外观', '主题、节点布局与排序', $r('app.media.ui_palette'), () => { this.openSettings('appearance') })
          this.ToolRow('网络设置', 'IPv6、局域网与 DNS', $r('app.media.ui_shield'), () => { this.openSettings('network') })
          this.ToolRow('延迟测试', '测试地址与超时', $r('app.media.ui_gauge'), () => { this.openSettings('delay') })
          this.ToolRow('备份与恢复', '导出配置与应用偏好', $r('app.media.ui_folder'), () => { this.openSettings('backup') })
          this.ToolRow('关于', 'Clash Harmony ' + APP_VERSION_NAME, $r('app.media.ui_info'), () => { this.openSettings('about') })
        }.padding({ left: AppTheme.gutter, right: AppTheme.gutter, bottom: 20 })
      }.layoutWeight(1).scrollBar(BarState.Off).width('100%')
    } else {
      Scroll() {
        Column({ space: 14 }) {
          if (this.diagSegment === '连接') {
            this.DiagnosticsConnectionSegment()
          } else if (this.diagSegment === '日志') {
            this.DiagnosticsLogSegment()
          } else if (this.diagSegment === '规则') {
            this.DiagnosticsRulesSegment()
          } else {
            this.DiagnosticsDnsSegment()
          }
        }.padding({ left: AppTheme.gutter, right: AppTheme.gutter, bottom: 20 })
      }.layoutWeight(1).scrollBar(BarState.Off).width('100%')
    }
  }

  @Builder
  private DiagnosticsConnectionSegment() {
    Column({ space: 12 }) {
      Column({ space: 10 }) {
        this.SectionTitle('连接概览', '关闭全部')
        Row({ space: 8 }) {
          this.Metric('活跃', `${this.liveConnections}`)
          this.Metric('下载', this.liveDownloadSpeed)
          this.Metric('上传', this.liveUploadSpeed)
        }
      }
      .padding(18).backgroundColor(AppTheme.surface).borderRadius(26)

      Column({ space: 8 }) {
        Row() {
          Text('核心 Controller').fontSize(15).fontWeight(FontWeight.Bold).fontColor(AppTheme.text)
          Button('刷新').height(44).fontSize(12).fontColor(AppTheme.surface)
            .backgroundColor(AppTheme.primary).borderRadius(8)
            .onClick(() => { this.refreshControllerStatus() })
        }
        .width('100%').justifyContent(FlexAlign.SpaceBetween)
        this.StatusLine(
          this.controllerStatus.available ? '已连接' : '未连接',
          this.controllerStatus.available ? `mihomo ${this.controllerStatus.version}` : this.controllerStatus.message,
          this.controllerStatus.available ? '正常' : '待接入'
        )
      }
      .padding(18).backgroundColor(AppTheme.surface).borderRadius(26)

      Button(this.advancedDiagnostics ? '收起高级诊断' : '展开高级诊断')
        .width('100%').height(48).backgroundColor(AppTheme.variant).fontColor(AppTheme.primary)
        .onClick(() => { this.advancedDiagnostics = !this.advancedDiagnostics })
      if (this.advancedDiagnostics) {
        Column({ space: 8 }) {
          this.SectionTitle('Native Bridge', '')
          this.StatusLine('桥接状态', this.coreBridgeState.coreMode,
            this.coreBridgeState.running ? '运行' : '待接入')
          this.StatusLine('Adapter', this.coreBridgeState.adapterVersion.length > 0
            ? `${this.coreBridgeState.adapterMode} ${this.coreBridgeState.adapterVersion}`
            : this.coreBridgeState.adapterMode,
            this.coreBridgeState.adapterMode === 'real' ? '真实核心' : 'Stub')
          if (this.coreBridgeState.adapterLoadError.length > 0) {
            this.StatusLine('加载信息', this.coreBridgeState.adapterLoadError,
              this.coreBridgeState.adapterMode === 'real' ? '正常' : '待接入')
          }
          this.StatusLine('TUN FD', `system ${this.coreBridgeState.tunFd} / native ${this.coreBridgeState.nativeFd}`,
            this.coreBridgeState.nativeFd >= 0 ? '正常' : '等待')
          this.StatusLine('Controller Ready',
            this.coreBridgeState.controllerReady ? `ready ${this.coreBridgeState.controllerVersion}` : 'not ready',
            this.coreBridgeState.controllerReady ? '正常' : '等待')
          this.StatusLine('转发统计',
            `读 ${this.coreBridgeState.packetsRead} 包 (${this.coreBridgeState.bytesRead} B) / 写 ${this.coreBridgeState.packetsWritten} 包 (${this.coreBridgeState.bytesWritten} B)`,
            this.coreBridgeState.forwarderActive ? '活跃' : '停用')
          this.StatusLine('生命周期',
            `start ${this.coreBridgeState.startCount} / stop ${this.coreBridgeState.stopCount}`,
            this.coreBridgeState.lastError.length > 0 ? '异常' : '正常')
          if (this.coreBridgeState.lastError.length > 0) {
            this.StatusLine('最近错误', this.coreBridgeState.lastError, '异常')
          }
        }
        .padding(18).backgroundColor(AppTheme.surface).borderRadius(26)

      }

      Column({ space: 8 }) {
        this.SectionTitle('运行配置', '')
        this.StatusLine(this.runtimeConfigInfo,
          this.runtimeConfigPath.length > 0 ? this.runtimeConfigPath : '等待生成',
          this.runtimeConfigInfo === '尚未生成运行配置' ? '待处理' : '正常')
        this.StatusLine('VPN 路由', '默认路由，接管 IPv4 流量', this.liveConnected ? '正常' : '未连接')
      }
      .padding(18).backgroundColor(AppTheme.surface).borderRadius(26)

      Column({ space: 8 }) {
        Row() {
          Text('活跃连接').fontSize(15).fontWeight(FontWeight.Bold).fontColor(AppTheme.text)
          Button('刷新').height(44).fontSize(12).fontColor(AppTheme.primary)
            .backgroundColor(AppTheme.primaryContainer).borderRadius(8)
            .onClick(() => { this.refreshConnections() })
        }
        .width('100%').justifyContent(FlexAlign.SpaceBetween)
        if (this.runtimeConnections.length === 0) {
          this.EmptyState('暂无连接数据', this.controllerStatus.available ? 'controller 已连接，等待连接产生。' : '启动 mihomo controller 后可同步活跃连接。')
        } else {
          ForEach(this.runtimeConnections, (item: RuntimeConnectionRow) => {
            this.ConnectionRow(item)
          }, (item: RuntimeConnectionRow) => item.id)
        }
      }
      .padding(18).backgroundColor(AppTheme.surface).borderRadius(26)
    }
  }

  @Builder
  private DiagnosticsLogSegment() {
    Column({ space: 8 }) {
      this.SectionTitle('最近日志', '导出')
      Text(this.backgroundStatus).fontSize(12).fontColor(AppTheme.muted)
      Button('刷新后台记录').height(36).onClick(() => { this.refreshLifecycleDiagnostics() })
      if (this.appLogs.length === 0) {
        this.LogLine('--:--', 'info', this.statusMessage)
        this.LogLine('--:--', 'info', this.controllerStatus.message)
      } else {
        ForEach(this.appLogs, (item: AppLogEntry) => {
          this.LogLine(item.time, item.level, item.message)
        }, (item: AppLogEntry) => `${item.time}-${item.message}`)
      }
      ForEach(this.lifecycleLogs.slice().reverse(), (line: string) => {
        Text(line).fontSize(11).fontColor(AppTheme.muted).width('100%')
      }, (line: string) => line)
    }
    .padding(18).backgroundColor(AppTheme.surface).borderRadius(26)
  }

  @Builder
  private DiagnosticsRulesSegment() {
    Column({ space: 8 }) {
      Row() {
        Text('规则').fontSize(15).fontWeight(FontWeight.Bold).fontColor(AppTheme.text)
        Button('刷新').height(44).fontSize(12).fontColor(AppTheme.surface)
          .backgroundColor(AppTheme.primary).borderRadius(8)
          .onClick(() => { this.refreshRules() })
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween)
      this.StatusLine('规则同步', this.rulesStatus, this.ruleLines.length > 0 ? '正常' : '待接入')
      if (this.ruleLines.length === 0) {
        this.EmptyState('暂无规则数据', '启动 mihomo controller 后可读取 /rules。')
      } else {
        ForEach(this.ruleLines, (line: string) => {
          this.MonospaceLine(line)
        }, (line: string) => line)
      }
    }
    .padding(18).backgroundColor(AppTheme.surface).borderRadius(26)
  }

  @Builder
  private DiagnosticsDnsSegment() {
    Column({ space: 8 }) {
      Row() {
        Text('DNS').fontSize(15).fontWeight(FontWeight.Bold).fontColor(AppTheme.text)
        Button('刷新').height(44).fontSize(12).fontColor(AppTheme.surface)
          .backgroundColor(AppTheme.primary).borderRadius(8)
          .onClick(() => { this.refreshDnsConfig() })
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween)
      this.StatusLine('DNS 配置', this.dnsStatus, this.dnsLines.length > 0 ? '正常' : '待接入')
      if (this.dnsLines.length === 0) {
        this.EmptyState('暂无 DNS 数据', '启动 mihomo controller 后可查看 DNS 配置。')
      } else {
        ForEach(this.dnsLines, (line: string) => {
          this.MonospaceLine(line)
        }, (line: string) => line)
      }
    }
    .padding(18).backgroundColor(AppTheme.surface).borderRadius(26)
  }

  @Builder
  private ConnectionRow(item: RuntimeConnectionRow) {
    Column({ space: 4 }) {
      Text(item.target).fontSize(13).fontWeight(FontWeight.Bold).fontColor(AppTheme.text)
      Text(`${item.rule} · ${item.chain.length > 0 ? item.chain : 'DIRECT'}`)
        .fontSize(11).fontColor(AppTheme.muted)
      Text(`上行 ${item.upload} / 下行 ${item.download}`).fontSize(11).fontColor(AppTheme.success)
    }
    .width('100%').alignItems(HorizontalAlign.Start).padding(10)
    .backgroundColor(AppTheme.background).borderRadius(8).border({ width: 1, color: AppTheme.outline })
  }

  @Builder
  private MonospaceLine(text: string) {
    Text(text).fontSize(11).fontColor(AppTheme.text)
      .width('100%').padding({ top: 4, bottom: 4 })
      .backgroundColor(AppTheme.background)
  }

  @Builder
  private ChoiceRow(title: string, subtitle: string, selected: boolean, action: () => void) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 14 }) {
        Column({ space: 4 }) {
          Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(AppTheme.text)
          if (subtitle.length > 0) {
            Text(subtitle).fontSize(12).fontColor(AppTheme.muted)
          }
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column() {
          if (selected) { this.Icon($r('app.media.ui_check'), 17, AppTheme.onPrimary) }
        }.width(24).height(24).justifyContent(FlexAlign.Center).borderRadius(12)
          .backgroundColor(selected ? AppTheme.primary : Color.Transparent)
          .border({ width: selected ? 0 : 2, color: AppTheme.outline })
      }.width('100%')
    }.width('100%').constraintSize({ minHeight: 66 }).padding(16)
      .backgroundColor(selected ? AppTheme.primaryContainer : AppTheme.surface)
      .borderRadius(20).onClick(() => { action() })
  }

  @Builder
  private SettingsScreen() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.settingsPage === 'root') {
          this.ToolRow('外观', '跟随系统、浅色与深色主题', $r('app.media.ui_palette'), () => { this.settingsPage = 'appearance' })
          this.ToolRow('网络设置', '连接、DNS 与日志等级', $r('app.media.ui_globe'), () => { this.settingsPage = 'network' })
          this.ToolRow('延迟测试', '测试地址与超时', $r('app.media.ui_gauge'), () => { this.settingsPage = 'delay' })
          this.ToolRow('备份与恢复', '保存配置文件与应用偏好', $r('app.media.ui_folder'), () => { this.settingsPage = 'backup' })
          this.ToolRow('关于', '版本信息与开源许可', $r('app.media.ui_info'), () => { this.settingsPage = 'about' })
        } else if (this.settingsPage === 'appearance') {
          this.SectionTitle('主题', '')
          this.ChoiceRow('跟随系统', '随系统外观自动切换', this.appPreferences.appearance === 'system',
            () => { this.appPreferences.appearance = 'system'; this.persistPreferences() })
          this.ChoiceRow('浅色', '明亮的 Material 色调', this.appPreferences.appearance === 'light',
            () => { this.appPreferences.appearance = 'light'; this.persistPreferences() })
          this.ChoiceRow('深色', '适合夜间的柔和对比', this.appPreferences.appearance === 'dark',
            () => { this.appPreferences.appearance = 'dark'; this.persistPreferences() })
          this.SectionTitle('代理布局', '')
          this.ChoiceRow('列表', '单列展示完整节点名称', this.appPreferences.proxyColumns === 1,
            () => { this.appPreferences.proxyColumns = 1; this.persistPreferences() })
          this.ChoiceRow('卡片', '双列浏览代理节点', this.appPreferences.proxyColumns === 2,
            () => { this.appPreferences.proxyColumns = 2; this.persistPreferences() })
          this.SectionTitle('节点排序', '')
          this.ChoiceRow('配置顺序', '', this.appPreferences.proxySort === 'original',
            () => { this.appPreferences.proxySort = 'original'; this.persistPreferences() })
          this.ChoiceRow('延迟优先', '已测出延迟的节点排在前面', this.appPreferences.proxySort === 'delay',
            () => { this.appPreferences.proxySort = 'delay'; this.persistPreferences() })
          this.ChoiceRow('名称', '', this.appPreferences.proxySort === 'name',
            () => { this.appPreferences.proxySort = 'name'; this.persistPreferences() })
        } else if (this.settingsPage === 'network') {
          this.Notice('网络设置保存后，在下一次连接或重新启动测速核心时生效。')
          Column({ space: 6 }) {
            Row({ space: 12 }) {
              Column({ space: 5 }) {
                Text('IPv6').fontSize(15).fontWeight(FontWeight.Medium).fontColor(AppTheme.text)
                Text('为代理核心与 DNS 启用 IPv6').fontSize(12).fontColor(AppTheme.muted)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.appPreferences.ipv6 }).selectedColor(AppTheme.primary)
                .onChange((value: boolean) => { this.appPreferences.ipv6 = value; this.persistPreferences() })
            }.width('100%').padding(16)
            Divider().color(AppTheme.outline)
            Row({ space: 12 }) {
              Column({ space: 5 }) {
                Text('允许局域网连接').fontSize(15).fontWeight(FontWeight.Medium).fontColor(AppTheme.text)
                Text('允许同一网络使用本机代理端口').fontSize(12).fontColor(AppTheme.muted)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.appPreferences.allowLan }).selectedColor(AppTheme.primary)
                .onChange((value: boolean) => { this.appPreferences.allowLan = value; this.persistPreferences() })
            }.width('100%').padding(16)
          }.backgroundColor(AppTheme.surface).borderRadius(24)
          this.SectionTitle('DNS 模式', '')
          this.ChoiceRow('redir-host', '返回真实 IP 地址', this.appPreferences.dnsMode === 'redir-host',
            () => { this.appPreferences.dnsMode = 'redir-host'; this.persistPreferences() })
          this.ChoiceRow('fake-ip', '使用虚拟 IP 映射', this.appPreferences.dnsMode === 'fake-ip',
            () => { this.appPreferences.dnsMode = 'fake-ip'; this.persistPreferences() })
          this.SectionTitle('日志等级', '')
          ForEach(['silent', 'error', 'warning', 'info', 'debug'], (level: string) => {
            this.ChoiceRow(level, '', this.appPreferences.logLevel === level,
              () => { this.appPreferences.logLevel = level; this.persistPreferences() })
          }, (level: string) => level)
          Column() {
            this.InfoRow('混合代理端口', '7890')
            this.InfoRow('本地控制器', '127.0.0.1:9090')
          }.padding(16).backgroundColor(AppTheme.surface).borderRadius(24)
        } else if (this.settingsPage === 'delay') {
          this.SectionTitle('超时时间', '')
          ForEach([3000, 4500, 8000, 10000], (duration: number) => {
            this.ChoiceRow((duration / 1000).toString() + ' 秒', '', this.appPreferences.testTimeout === duration,
              () => { this.appPreferences.testTimeout = duration; this.persistPreferences() })
          }, (duration: number) => duration.toString())
          this.SectionTitle('首选测试地址', '')
          this.ChoiceRow('Cloudflare', 'cp.cloudflare.com', this.appPreferences.testUrl === DELAY_TEST_URLS[0],
            () => { this.appPreferences.testUrl = DELAY_TEST_URLS[0]; this.persistPreferences() })
          this.ChoiceRow('Google', 'www.gstatic.com', this.appPreferences.testUrl === DELAY_TEST_URLS[1],
            () => { this.appPreferences.testUrl = DELAY_TEST_URLS[1]; this.persistPreferences() })
          this.ChoiceRow('华为', 'connectivitycheck.platform.hicloud.com', this.appPreferences.testUrl === DELAY_TEST_URLS[2],
            () => { this.appPreferences.testUrl = DELAY_TEST_URLS[2]; this.persistPreferences() })
          this.Notice('首选地址失败时会尝试其他测试地址。延迟测试不代表下载带宽。')
        } else if (this.settingsPage === 'backup') {
          this.ToolRow('导出备份', '保存所有配置内容与应用偏好', $r('app.media.ui_up'), () => { this.exportAppBackup() })
          this.ToolRow('从文件恢复', '选择 Clash Harmony JSON 备份', $r('app.media.ui_down'), () => { this.pickAppBackup() })
          this.ToolRow('导出运行日志', '保存当前应用记录的操作日志', $r('app.media.ui_file'), () => { this.exportAppLogs() })
          this.Notice('备份包含订阅链接与节点凭据，请保存在你信任的位置。')
        } else {
          Column({ space: 14 }) {
            this.Icon($r('app.media.ui_shield'), 58, AppTheme.primary)
            Text('Clash Harmony').fontSize(24).fontWeight(FontWeight.Bold).fontColor(AppTheme.text)
            Text('版本 ' + APP_VERSION_NAME).fontSize(13).fontColor(AppTheme.muted)
            Text('为 HarmonyOS 构建的 Mihomo 代理客户端').fontSize(13).fontColor(AppTheme.muted)
          }.width('100%').padding(32).backgroundColor(AppTheme.surface).borderRadius(28)
          Column() {
            this.InfoRow('界面参考', 'FlClash 0.9.2')
            this.InfoRow('开源许可', 'GPL-3.0-only')
            this.InfoRow('内核版本', this.controllerStatus.available ? this.controllerStatus.version : '连接后显示')
          }.padding(16).backgroundColor(AppTheme.surface).borderRadius(24)
          Hyperlink('https://github.com/LiMoRan123/clash-harmony', '查看源代码')
            .color(AppTheme.primary).padding(16)
          this.Notice('基于 Clash Harmony 与 Mihomo。界面使用 ArkUI 原生组件。')
        }
      }.padding({ left: AppTheme.gutter, right: AppTheme.gutter, bottom: 28 })
    }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
  }

  private pageTitle(): string {
    if (this.showSettings) {
      if (this.settingsPage === 'appearance') { return '外观' }
      if (this.settingsPage === 'network') { return '网络设置' }
      if (this.settingsPage === 'delay') { return '延迟测试' }
      if (this.settingsPage === 'backup') { return '备份与恢复' }
      if (this.settingsPage === 'about') { return '关于' }
      return '设置';
    }
    if (this.toolPage.length > 0) { return this.toolPage === '连接' ? '实时连接' : this.toolPage === '日志' ? '运行日志' : this.toolPage }
    if (this.currentTab === 'proxies') { return '代理' }
    if (this.currentTab === 'profiles') { return '配置' }
    if (this.currentTab === 'diagnostics') { return '工具' }
    return '仪表盘';
  }

  private openSettings(page: string): void {
    this.settingsPage = page;
    this.showSettings = true;
  }

  private openTool(segment: string): void {
    this.diagSegment = segment;
    this.toolPage = segment;
    if (segment === '连接') { this.refreshConnections() }
    if (segment === '规则') { this.refreshRules() }
    if (segment === 'DNS') { this.refreshDnsConfig() }
  }

  private isRejectPolicy(name: string): boolean {
    return name === 'REJECT' || name === 'REJECT-DROP';
  }

  private nodeDelayColor(node: ProxyNode): ResourceColor {
    if (this.isRejectPolicy(node.name)) { return AppTheme.muted }
    if (node.status === 'dead') { return AppTheme.danger }
    if (node.status === 'testing') { return AppTheme.primary }
    if (node.status === 'slow') { return AppTheme.warning }
    if (node.status === 'fast' || node.status === 'normal') { return AppTheme.success }
    return AppTheme.muted;
  }


  private async checkExitIp(): Promise<void> {
    if (!this.liveConnected || this.checkingExit) { return }
    this.checkingExit = true;
    try {
      const ip: string = await NetworkProbeService.exitIp();
      if (this.liveConnected) { this.exitIp = ip }
    } catch (err) {
      this.notify('出口检测失败，请确认当前代理可用后重试');
    } finally {
      this.checkingExit = false;
    }
  }

  private proxyDisplayMenu(): MenuElement[] {
    return [
      { value: '配置顺序', action: () => { this.appPreferences.proxySort = 'original'; this.persistPreferences() } },
      { value: '按延迟排序', action: () => { this.appPreferences.proxySort = 'delay'; this.persistPreferences() } },
      { value: '按名称排序', action: () => { this.appPreferences.proxySort = 'name'; this.persistPreferences() } },
      { value: this.appPreferences.proxyColumns === 1 ? '切换双列卡片' : '切换单列列表',
        action: () => { this.appPreferences.proxyColumns = this.appPreferences.proxyColumns === 1 ? 2 : 1; this.persistPreferences() } }
    ];
  }

  private profileMenu(item: ClashProfile): MenuElement[] {
    const actions: MenuElement[] = [
      { value: '编辑配置与名称', action: () => { this.openProfileEditor(item) } },
      { value: '导出 YAML', action: () => { this.exportProfile(item) } }
    ];
    if (item.type === 'remote') {
      actions.push({ value: '复制订阅链接', action: () => { this.copySubscription(item) } });
    }
    actions.push({ value: '删除配置', action: () => {
      AlertDialog.show({
        title: '删除配置？', message: '将从应用中移除“' + item.name + '”。',
        primaryButton: { value: '取消', action: () => {} },
        secondaryButton: { value: '删除', fontColor: AppTheme.danger, action: () => { this.removeProfile(item.uid) } }
      });
    } });
    return actions;
  }

  private async copySubscription(item: ClashProfile): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, item.source));
      this.notify('订阅链接已复制');
    } catch (err) { this.notify('复制失败，请重试') }
  }

  private async openProfileEditor(item: ClashProfile): Promise<void> {
    if (this.profileUpdate.running || this.profileMutationBusy || this.toggling) { return }
    if (item.filePath.length === 0) { this.notify('请先更新订阅，再编辑配置'); return }
    try {
      this.editorUid = item.uid;
      this.editorName = item.name;
      this.editorText = await fileIo.readText(item.filePath);
      this.sheetKind = 'editor';
      this.showImportPanel = true;
    } catch (err) { this.notify('配置文件无法读取，请重新更新订阅') }
  }

  private async saveProfileEditor(): Promise<void> {
    if (this.editorSaving || this.profileUpdate.running || this.profileMutationBusy) { return }
    const converted = GenericSubscriptionConverterService.normalizeToClashYaml(this.editorText);
    if (!converted.ok) { this.notify(converted.message); return }
    if (this.editorName.trim().length === 0) { this.notify('请填写配置名称'); return }
    this.editorSaving = true;
    this.profileMutationBusy = true;
    try {
      const context = getContext(this) as common.Context;
      const state: ProfileState = await ProfileStore.load(context);
      const item: ClashProfile | undefined = state.items.find((profile: ClashProfile) => profile.uid === this.editorUid);
      if (!item) { this.notify('配置已被移除'); return }
      const file: fileIo.File = fileIo.openSync(item.filePath, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try { await fileIo.write(file.fd, converted.text); } finally { fileIo.closeSync(file); }
      item.name = this.editorName.trim();
      item.updatedAt = Date.now();
      item.nodeCount = ClashConfigParserService.parseProxyNodes(converted.text).length;
      const next: ProfileState = await ProfileStore.replace(context, item);
      this.applyProfileState(next);
      await this.refreshProxyNodes(next);
      this.showImportPanel = false;
      this.notify('配置已保存，重新连接后生效');
    } catch (err) { this.notify('保存失败，请检查配置文件') }
    finally { this.editorSaving = false; this.profileMutationBusy = false }
  }

  private async exportProfile(item: ClashProfile): Promise<void> {
    if (item.filePath.length === 0) { this.notify('请先更新订阅'); return }
    try {
      const content: string = await fileIo.readText(item.filePath);
      const saved: boolean = await DocumentExportService.save(getContext(this) as common.Context,
        item.name.replace(/[\\/:*?"<>|]/g, '_') + '.yaml', content);
      if (saved) { this.notify('配置已导出') }
    } catch (err) { this.notify('配置导出失败') }
  }

  private async exportAppLogs(): Promise<void> {
    try {
      this.refreshLifecycleDiagnostics();
      const lines: string[] = this.appLogs.map((item: AppLogEntry) => item.time + ' [' + item.level + '] ' + item.message);
      lines.push(...this.lifecycleLogs);
      if (await DocumentExportService.save(getContext(this) as common.Context, 'clash-harmony.log', lines.join('\n'))) {
        this.notify('日志已导出');
      }
    } catch (err) { this.notify('日志导出失败') }
  }

  private async exportAppBackup(): Promise<void> {
    try {
      const context = getContext(this) as common.Context;
      const content: string = await AppBackupService.create(context);
      if (await DocumentExportService.save(context, 'clash-harmony-backup.json', content)) {
        this.notify('备份已导出');
      }
    } catch (err) { this.notify('备份导出失败，请确认配置文件可读取') }
  }

  private async pickAppBackup(): Promise<void> {
    if (this.profileUpdate.running || this.profileMutationBusy) { this.notify('请等待配置更新完成'); return }
    if (this.liveConnected || this.toggling) { this.notify('请先断开 VPN 再恢复备份'); return }
    try {
      const context = getContext(this) as common.Context;
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const uris: string[] = await documentPicker.select({ maxSelectNumber: 1, fileSuffixFilters: ['JSON|.json'] });
      if (uris.length === 0) { return }
      const content: string = await fileIo.readText(uris[0]);
      AlertDialog.show({
        title: '恢复备份？', message: '恢复将替换当前配置列表与偏好设置，建议先导出一份备份。',
        primaryButton: { value: '取消', action: () => {} },
        secondaryButton: { value: '恢复', action: () => { this.restoreAppBackup(content) } }
      });
    } catch (err) { this.notify('备份文件无法读取') }
  }

  private async restoreAppBackup(content: string): Promise<void> {
    if (this.profileUpdate.running || this.profileMutationBusy) { this.notify('请等待配置更新完成'); return }
    this.profileMutationBusy = true;
    try {
      const next: ProfileState = await AppBackupService.restore(getContext(this) as common.Context, content);
      this.applyProfileState(next);
      await this.refreshProxyNodes(next);
      await this.loadAppPreferences();
      this.notify('备份已恢复');
    } catch (err) { this.notify(err instanceof Error ? err.message : '恢复失败，请检查备份文件') }
    finally { this.profileMutationBusy = false }
  }

  // ============== Helpers ==============
  private async runRealSpeedTest(): Promise<void> {
    if (this.isSpeedTesting) {
      this.statusMessage = '测速正在进行，请稍候';
      return;
    }

    let targetIndexes: number[] = this.getAllProxyNodeIndexes();
    let targetNodes: ProxyNode[] = this.createProxyNodeSnapshot(targetIndexes);
    if (targetNodes.length === 0) {
      this.statusMessage = '没有节点可测';
      this.speedTestProgress = '没有节点可测';
      this.speedTestSummary = '没有节点可测';
      return;
    }

    this.isSpeedTesting = true;
    this.speedTestSummary = '';
    this.speedTestProgress = `准备测速核心 · ${targetNodes.length} 个节点`;
    this.statusMessage = `正在准备测速 ${targetNodes.length} 个节点...`;
    await this.waitForUiUpdate(80);

    let tested: number = 0;
    let reachable: number = 0;
    let timeout: number = 0;

    try {
      const ready: boolean = await this.ensureControllerReadyForProxyActions('测速');
      if (!ready) {
        this.speedTestProgress = '测速未开始：controller 未就绪';
        this.speedTestSummary = this.speedTestProgress;
        return;
      }

      targetIndexes = this.getAllProxyNodeIndexes();
      targetNodes = this.createProxyNodeSnapshot(targetIndexes);
      if (targetNodes.length === 0) {
        this.speedTestProgress = '没有节点可测';
        this.speedTestSummary = '没有节点可测';
        this.statusMessage = '没有节点可测';
        return;
      }

      const blocked: SpeedTestBlockedState | undefined = this.getSpeedTestBlockedState(targetNodes.length);
      if (blocked) {
        this.updateProxyNodeDelayBatch(this.createDelayUpdates(targetNodes, blocked.nodeDelay, blocked.nodeStatus));
        this.statusMessage = blocked.statusMessage;
        this.speedTestProgress = blocked.progress;
        this.speedTestSummary = blocked.summary;
        this.recordLog('warn', blocked.statusMessage);
        return;
      }

      this.speedTestProgress = `测速中 0/${targetNodes.length} · 0 可达`;
      this.statusMessage = `正在测速 0/${targetNodes.length}...`;
      this.updateProxyNodeDelayBatch(this.createDelayUpdates(targetNodes, '测试中...', 'testing'));

      await this.waitForUiUpdate(80);

      const batchSize: number = 12;
      for (let offset = 0; offset < targetNodes.length; offset += batchSize) {
        const batchNodes: ProxyNode[] = [];
        const tasks: Promise<number>[] = [];
        const end: number = offset + batchSize > targetNodes.length ? targetNodes.length : offset + batchSize;
        for (let cursor = offset; cursor < end; cursor++) {
          const node: ProxyNode = targetNodes[cursor];
          batchNodes.push(node);
          tasks.push(this.measureProxyNodeDelay(node));
        }

        const delays: number[] = await Promise.all(tasks);
        const updates: ProxyDelayUpdate[] = [];
        for (let index = 0; index < delays.length; index++) {
          const node: ProxyNode = batchNodes[index];
          const result = TcpDelayTestService.formatDelay(delays[index]);
          updates.push({ name: node.name, delay: result.delay, status: result.status });
          tested = tested + 1;
          if (delays[index] > 0) {
            reachable = reachable + 1;
          } else {
            timeout = timeout + 1;
          }
        }
        this.updateProxyNodeDelayBatch(updates);
        this.speedTestProgress = '测速中 ' + tested + '/' + targetNodes.length + ' · ' + reachable + ' 可达 · ' + timeout + ' timeout';
        this.statusMessage = '测速: ' + tested + '/' + targetNodes.length + ' (' + reachable + ' 可达)';
        await this.waitForUiUpdate(0);
      }
      this.speedTestSummary = '测速完成 ' + tested + '/' + targetNodes.length + ' · ' + reachable + ' 可达 · ' + timeout + ' timeout';
      this.speedTestProgress = this.speedTestSummary;
      this.statusMessage = '测速完成: ' + tested + ' 个节点, ' + reachable + ' 可达';
      await this.autoSelectReachableProxyAfterSpeedTest();
    } finally {
      this.isSpeedTesting = false;
    }
  }

  private waitForUiUpdate(durationMs: number): Promise<void> {
    return new Promise((resolve: () => void) => {
      setTimeout(resolve, durationMs);
    });
  }

  private async measureProxyNodeDelay(node: ProxyNode): Promise<number> {
    if (!this.controllerStatus.available && !this.coreBridgeState.controllerReady) {
      return -1;
    }

    if (this.isRejectPolicy(node.name)) {
      return -1;
    }
    const testUrls: string[] = [this.appPreferences.testUrl, DELAY_TEST_URLS[0], DELAY_TEST_URLS[1], DELAY_TEST_URLS[2]];
    for (let urlIndex = 0; urlIndex < testUrls.length; urlIndex++) {
      const result: ControllerTextResult = await MihomoControllerService.testDelay(
        node.name,
        this.appPreferences.testTimeout,
        testUrls[urlIndex]
      );
      const delay: number = this.parseControllerDelay(result);
      if (delay > 0) {
        return delay;
      }
    }
    return -1;
  }

  private async verifySelectedProxyAfterConnection(controllerVersion: string): Promise<void> {
    const generation: number = this.homeRefreshGeneration;
    const group: ProxyGroupInfo | undefined = this.findRuntimeProxyGroup();
    const nodeName: string = group && group.now.length > 0 ? group.now : this.getSelectedProxyNodeName();
    if (nodeName.length === 0) {
      this.clearProxyHealthState();
      this.statusMessage = `已连接 · ${controllerVersion} · 未找到当前节点`;
      this.recordLog('warn', this.statusMessage);
      return;
    }
    if (this.isRejectPolicy(nodeName)) {
      this.clearProxyHealthState();
      this.statusMessage = 'VPN 已连接 · 当前检查策略为拒绝连接，不参与延迟测试';
      return;
    }

    this.statusMessage = `VPN 隧道已建立，正在检测当前节点：${nodeName}`;
    this.syncHomeRuntimeFields();
    const delay: number = await this.measureProxyNodeDelay({
      name: nodeName,
      meta: '',
      delay: '待测',
      selected: true
    });

    if (generation !== this.homeRefreshGeneration || !this.isRuntimeConnected()) { return }
    this.proxyHealthCheckedAt = Date.now();
    this.proxyHealthNode = nodeName;
    this.proxyHealthOk = delay > 0;
    this.proxyHealthDelay = delay > 0 ? delay : 0;
    if (delay > 0) {
      this.statusMessage = `已连接 · ${controllerVersion} · 当前节点可达 ${delay} ms`;
      this.recordLog('info', this.statusMessage);
      return;
    }

    this.statusMessage = `VPN 隧道已建立，但当前节点不可达：${nodeName} · 请在代理页重新测速并切换节点`;
    this.recordLog('warn', this.statusMessage);
  }

  private clearProxyHealthState(): void {
    this.proxyHealthCheckedAt = 0;
    this.proxyHealthOk = false;
    this.proxyHealthDelay = 0;
    this.proxyHealthNode = '';
  }


  private async autoSelectReachableProxyAfterSpeedTest(): Promise<void> {
    const selectedName: string = this.getSelectedProxyNodeName();
    let selectedReachable: boolean = false;
    let bestNode: ProxyNode | undefined = undefined;
    let bestDelay: number = 0;

    for (let index = 0; index < this.proxyNodes.length; index++) {
      const node: ProxyNode = this.proxyNodes[index];
      const delay: number = this.parseDelayText(node.delay);
      if (delay <= 0) {
        continue;
      }
      if (node.name === selectedName) {
        selectedReachable = true;
      }
      if (!bestNode || delay < bestDelay) {
        bestNode = node;
        bestDelay = delay;
      }
    }

    if (!bestNode) {
      return;
    }
    if (selectedReachable && selectedName.length > 0) {
      return;
    }

    const group: ProxyGroupInfo | undefined = this.findSelectedProxyGroup();
    if (!group) {
      this.markSelectedProxyNode(bestNode.name);
      this.pendingProxyName = bestNode.name;
      this.statusMessage = `当前节点不可达，已预选最快可达节点：${bestNode.name} · ${bestNode.delay}`;
      this.recordLog('info', this.statusMessage);
      this.syncHomeRuntimeFields();
      return;
    }

    const ok: boolean = await MihomoControllerService.selectProxy(group.name, bestNode.name);
    if (!ok) {
      this.statusMessage = `最快可达节点选择失败：${group.name} -> ${bestNode.name}`;
      this.recordLog('warn', this.statusMessage);
      return;
    }

    this.pendingProxyGroup = group.name;
    this.pendingProxyName = bestNode.name;
    this.markSelectedProxyNode(bestNode.name);
    await this.refreshControllerProxies();
    this.statusMessage = `当前节点不可达，已切换最快可达节点：${bestNode.name} · ${bestNode.delay}`;
    this.speedTestProgress = `${this.speedTestSummary} · 已切换 ${bestNode.delay}`;
    this.recordLog('info', this.statusMessage);
    this.syncHomeRuntimeFields();
  }

  private parseDelayText(delay: string): number {
    if (delay.endsWith(' ms')) {
      return parseInt(delay.substring(0, delay.length - 3));
    }
    return 0;
  }

  private getSpeedTestBlockedState(targetCount: number): SpeedTestBlockedState | undefined {
    if (!this.controllerStatus.available && !this.coreBridgeState.controllerReady) {
      return {
        nodeDelay: '核心未就绪',
        nodeStatus: 'pending',
        statusMessage: `controller 未就绪，未对 ${targetCount} 个节点发起测速`,
        progress: `未开始：controller 未就绪，未对 ${targetCount} 个节点发起测速`,
        summary: '测速未开始：controller 未就绪；节点未标记 timeout'
      };
    }

    return undefined;
  }

  private parseControllerDelay(result: ControllerTextResult): number {
    if (!result.ok) {
      return -1;
    }
    try {
      const parsed = JSON.parse(result.raw) as Record<string, number>;
      const delay: number = parsed['delay'];
      return delay > 0 ? delay : -1;
    } catch (err) {
      return -1;
    }
  }

  private async waitForVpnTunReady(maxAttempts: number, intervalMs: number): Promise<RuntimeTunStatus> {
    let latest: RuntimeTunStatus = {
      ready: false,
      message: 'VPN TUN 尚未就绪',
      raw: '',
      enabled: false,
      fileDescriptor: 0,
      stack: ''
    };

    for (let index = 0; index < maxAttempts; index++) {
      const result: ControllerTextResult = await MihomoControllerService.getConfig();
      if (result.ok) {
        latest = this.parseRuntimeTunStatus(result.raw);
      } else {
        latest = {
          ready: false,
          message: `读取 TUN 状态失败：${result.message}`,
          raw: result.raw,
          enabled: false,
          fileDescriptor: 0,
          stack: ''
        };
      }

      if (latest.ready) {
        this.proxyMode = this.parseControllerMode(latest.raw);
        return latest;
      }
      if (index < maxAttempts - 1) {
        await this.waitForUiUpdate(intervalMs);
      }
    }
    return latest;
  }

  private parseRuntimeTunStatus(raw: string): RuntimeTunStatus {
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const tun = parsed['tun'] as Record<string, Object>;
      if (!tun) {
        return {
          ready: false,
          message: 'VPN TUN 未启用：controller 未返回 tun 配置',
          raw: raw,
          enabled: false,
          fileDescriptor: 0,
          stack: ''
        };
      }

      const enabled: boolean = tun['enable'] === true;
      const fdValue: Object = tun['file-descriptor'];
      const fileDescriptor: number = typeof fdValue === 'number' ? fdValue as number : 0;
      const stackValue: Object = tun['stack'];
      const stack: string = typeof stackValue === 'string' ? stackValue as string : '';
      const ready: boolean = enabled && fileDescriptor > 0;
      return {
        ready: ready,
        message: ready ? `VPN TUN 已启用：fd=${fileDescriptor} stack=${stack}` :
          `VPN TUN 未启用：enable=${enabled ? 'true' : 'false'} fd=${fileDescriptor} stack=${stack}`,
        raw: raw,
        enabled: enabled,
        fileDescriptor: fileDescriptor,
        stack: stack
      };
    } catch (err) {
      return {
        ready: false,
        message: 'VPN TUN 状态解析失败',
        raw: raw,
        enabled: false,
        fileDescriptor: 0,
        stack: ''
      };
    }
  }

  private updateProxyNodeDelay(targetIndex: number, targetName: string, delay: string, status: string): void {
    this.updateProxyNodeDelayBatch([{ name: targetName, delay: delay, status: status }]);
  }

  private updateVisibleProxyNodeDelay(targetIndexes: number[], delay: string, status: string): void {
    const updates: ProxyDelayUpdate[] = [];
    for (let index = 0; index < targetIndexes.length; index++) {
      const nodeIndex: number = targetIndexes[index];
      if (nodeIndex >= 0 && nodeIndex < this.proxyNodes.length) {
        updates.push({ name: this.proxyNodes[nodeIndex].name, delay: delay, status: status });
      }
    }
    this.updateProxyNodeDelayBatch(updates);
  }

  private updateProxyNodeDelayBatch(updates: ProxyDelayUpdate[]): void {
    if (updates.length === 0) {
      return;
    }

    const updateMap: Record<string, ProxyDelayState> = {};
    for (let index = 0; index < updates.length; index++) {
      const update: ProxyDelayUpdate = updates[index];
      if (update.name.length === 0) {
        continue;
      }
      updateMap[update.name] = {
        delay: update.delay,
        status: update.status
      };
      this.proxyDelayCache[update.name] = {
        delay: update.delay,
        status: update.status
      };
    }

    const nodes: ProxyNode[] = [];
    for (let index = 0; index < this.proxyNodes.length; index++) {
      const node: ProxyNode = this.proxyNodes[index];
      const updated: ProxyDelayState | undefined = updateMap[node.name];
      if (updated) {
        nodes.push(this.copyProxyNodeWithDelay(node, updated.delay, updated.status));
      } else {
        const cached: ProxyDelayState = this.getCachedProxyDelayState(node.name);
        nodes.push(this.copyProxyNodeWithDelay(node, cached.delay, cached.status));
      }
    }
    this.proxyNodes = nodes;
  }

  private createProxyNodeSnapshot(indexes: number[]): ProxyNode[] {
    const nodes: ProxyNode[] = [];
    for (let index = 0; index < indexes.length; index++) {
      const nodeIndex: number = indexes[index];
      if (nodeIndex < 0 || nodeIndex >= this.proxyNodes.length) {
        continue;
      }
      const node: ProxyNode = this.proxyNodes[nodeIndex];
      nodes.push({
        name: node.name,
        meta: node.meta,
        delay: node.delay,
        selected: node.selected,
        status: node.status,
        server: node.server,
        port: node.port
      });
    }
    return nodes;
  }

  private createDelayUpdates(nodes: ProxyNode[], delay: string, status: string): ProxyDelayUpdate[] {
    const updates: ProxyDelayUpdate[] = [];
    for (let index = 0; index < nodes.length; index++) {
      updates.push({ name: nodes[index].name, delay: delay, status: status });
    }
    return updates;
  }

  private getCachedProxyDelayState(name: string): ProxyDelayState {
    const cached: ProxyDelayState | undefined = this.proxyDelayCache[name];
    if (cached && cached.delay.length > 0) {
      return {
        delay: cached.delay,
        status: cached.status
      };
    }
    return {
      delay: '待测',
      status: 'pending'
    };
  }

  private copyProxyNodeWithDelay(node: ProxyNode, delay: string, status: string): ProxyNode {
    return {
      name: node.name,
      meta: node.meta,
      delay: delay,
      selected: node.selected,
      status: status,
      server: node.server ? node.server : '',
      port: node.port ? node.port : 0
    };
  }

  private createProfileNameFromUrl(url: string): string {
    let value: string = url;
    value = value.replace('https://', '').replace('http://', '');
    const slashIndex: number = value.indexOf('/');
    if (slashIndex > 0) { value = value.substring(0, slashIndex) }
    return value.length > 0 ? value : '远程订阅';
  }
}
