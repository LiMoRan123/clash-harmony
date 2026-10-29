import { AbilityConstant, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VpnExtensionAbility, vpnExtension } from '@kit.NetworkKit';
import { CoreBridgeService, CoreBridgeState } from '../services/CoreBridgeService';
import { ControllerStatus, MihomoControllerService } from '../services/MihomoControllerService';
import nativeCore from 'libentry.so';
import { VpnRuntimeEvents } from '../services/VpnRuntimeEvents';
import { VpnControlChannel } from '../services/VpnControlChannel';
import { RuntimeDiagnostics } from '../services/RuntimeDiagnostics';

const DOMAIN: number = 0x0001;
const TAG: string = 'ClashVpnExtension';
const PARAM_CONFIG_PATH: string = 'configPath';

export default class ClashVpnExtensionAbility extends VpnExtensionAbility {
  private connection?: vpnExtension.VpnConnection;
  private tunFd: number = -1;
  private configPath: string = '';
  private starting: boolean = false;
  private stopping: boolean = false;
  private stopTask?: Promise<void>;
  private sessionId: string = '';
  private eventSequence: number = 0;
  private startedAt: number = 0;
  private phase: string = 'creating';
  private controllerVersion: string = '';
  private requestedStop: boolean = false;
  private destroyed: boolean = false;
  private control: VpnControlChannel = new VpnControlChannel();
  private controlReady?: Promise<void>;

  private publishPhase(phase: string, version: string = ''): void {
    this.phase = phase;
    if (version.length > 0) { this.controllerVersion = version }
    if (this.sessionId.length === 0) { return }
    const elapsed: number = Math.max(0, Date.now() - this.startedAt);
    this.eventSequence++;
    VpnRuntimeEvents.publish({
      sessionId: this.sessionId, sequence: this.eventSequence, phase: phase, elapsedMs: elapsed,
      version: phase === 'connected' ? this.controllerVersion : ''
    });
    hilog.info(DOMAIN, TAG, 'VPN phase=%{public}s elapsedMs=%{public}d', phase, elapsed);
    RuntimeDiagnostics.append(this.context, 'vpn', '阶段 ' + phase + '，耗时 ' + elapsed + ' ms');
  }

  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, 'VPN extension created');
    this.connection = vpnExtension.createVpnConnection(this.context);
    try {
      nativeCore.protectSocket(-1);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Socket protection setup check: %{public}s', JSON.stringify(err));
    }
    this.captureWant(want);
    this.controlReady = this.control.subscribe((action: string, session: string) => {
      if (session.length > 0 && session !== this.sessionId) { return }
      if (action === 'status') {
        this.publishPhase(this.phase);
      } else if (action === 'stop') {
        if (this.requestedStop) { return }
        this.requestedStop = true;
        RuntimeDiagnostics.append(this.context, 'vpn', '收到用户断开请求');
        this.stopTunnel().then(() => {
          if (this.destroyed) { return }
          return vpnExtension.stopVpnExtensionAbility({
            bundleName: 'io.github.clashharmony.app', abilityName: 'ClashVpnExtensionAbility'
          });
        }).catch(() => { RuntimeDiagnostics.append(this.context, 'vpn', '扩展停止请求未完成') });
      }
    }).catch(() => { RuntimeDiagnostics.append(this.context, 'vpn', '控制事件订阅失败，使用系统停止兼容路径') });
    this.controlReady.then(() => { this.startTunnel() });
  }

  onRequest(want: Want, startId: number): void {
    hilog.info(DOMAIN, TAG, 'VPN extension requested: %{public}d', startId);
    this.captureWant(want);
    (this.controlReady ?? Promise.resolve()).then(() => { this.startTunnel() });
  }

  onDestroy(): void {
    this.destroyed = true;
    hilog.info(DOMAIN, TAG, 'VPN extension destroyed');
    RuntimeDiagnostics.append(this.context, 'vpn', this.requestedStop ? '用户断开后扩展销毁' : '扩展被系统或外部停止');
    this.control.close();
    this.stopping = true;
    this.stopTunnel();
  }

  onMemoryLevel(level: AbilityConstant.MemoryLevel): void {
    RuntimeDiagnostics.append(this.context, 'vpn', '内存压力等级 ' + level);
  }

  private captureWant(want: Want): void {
    if (!want.parameters) {
      return;
    }

    const value: Object | undefined = want.parameters[PARAM_CONFIG_PATH];
    if (typeof value === 'string') {
      this.configPath = value;
    }
    const session: Object | undefined = want.parameters['sessionId'];
    if (typeof session === 'string' && session.length > 0 && !this.starting && this.tunFd < 0) {
      this.sessionId = session;
    }
  }

  private async startTunnel(): Promise<void> {
    if (this.starting || this.stopping || this.tunFd >= 0) {
      return;
    }
    const connection: vpnExtension.VpnConnection | undefined = this.connection;
    if (!connection) {
      hilog.error(DOMAIN, TAG, 'VPN connection is not ready');
      return;
    }

    this.starting = true;
    this.startedAt = Date.now();
    this.publishPhase('creating');
    try {
      const config: vpnExtension.VpnConfig = this.createSafeTunConfig();
      const fd: number = await connection.create(config);
      if (this.stopping) {
        await connection.destroy();
        return;
      }
      this.tunFd = fd;
      hilog.info(DOMAIN, TAG, 'VPN TUN created, fd=%{public}d, config=%{public}s', this.tunFd, this.configPath);
      try {
        await connection.protectProcessNet();
        hilog.info(DOMAIN, TAG, 'VPN process network protected for native core outbound sockets');
      } catch (protectErr) {
        hilog.warn(DOMAIN, TAG, 'VPN process network protection failed: %{public}s', JSON.stringify(protectErr));
      }
      if (this.stopping) {
        await connection.destroy();
        this.tunFd = -1;
        return;
      }
      this.publishPhase('starting');
      const coreState: CoreBridgeState = await CoreBridgeService.startTun(this.configPath, this.tunFd);
      if (this.stopping) {
        await CoreBridgeService.stopTun();
        return;
      }
      if (!coreState.running) {
        hilog.error(DOMAIN, TAG, 'Native core bridge failed: error=%{public}s adapter=%{public}s adapterKind=%{public}s loadError=%{public}s nativeFd=%{public}d',
          coreState.lastError, coreState.adapterMode, coreState.adapterKind, coreState.adapterLoadError, coreState.nativeFd);
        await this.stopTunnel();
        this.publishPhase('error');
      } else {
        hilog.info(DOMAIN, TAG, 'Native core bridge started: mode=%{public}s adapter=%{public}s adapterVersion=%{public}s nativeFd=%{public}d adapterKind=%{public}s realReady=%{public}s supportsControllerOnly=%{public}s',
          coreState.coreMode, coreState.adapterMode, coreState.adapterVersion, coreState.nativeFd,
          coreState.adapterKind, coreState.realConnectionReady ? 'true' : 'false',
          coreState.supportsControllerOnly ? 'true' : 'false');
        hilog.info(DOMAIN, TAG, 'Forwarder stats: packetsRead=%{public}d packetsWritten=%{public}d bytesRead=%{public}d bytesWritten=%{public}d readErrors=%{public}d writeErrors=%{public}d forwarderActive=%{public}s',
          coreState.packetsRead, coreState.packetsWritten, coreState.bytesRead, coreState.bytesWritten,
          coreState.readErrors, coreState.writeErrors, coreState.forwarderActive ? 'true' : 'false');
        await this.markControllerReadyInVpnProcess();
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to create VPN TUN: %{public}s', JSON.stringify(err));
      this.tunFd = -1;
      await this.stopTunnel();
      this.publishPhase('error');
    } finally {
      this.starting = false;
    }
  }

  private async markControllerReadyInVpnProcess(): Promise<void> {
    if (this.stopping) {
      return;
    }
    this.publishPhase('verifying');
    const controllerReady: ControllerStatus = await MihomoControllerService.waitForVersion(10, 150);
    if (this.stopping) {
      return;
    }
    if (controllerReady.available) {
      const readyState: CoreBridgeState = CoreBridgeService.markControllerReady(true, controllerReady.version);
      this.publishPhase('connected', controllerReady.version);
      hilog.info(DOMAIN, TAG, 'Controller ready: controllerVersion=%{public}s adapter=%{public}s adapterVersion=%{public}s nativeFd=%{public}d realReady=%{public}s forwarderActive=%{public}s',
        controllerReady.version, readyState.adapterMode, readyState.adapterVersion, readyState.nativeFd,
        readyState.realConnectionReady ? 'true' : 'false', readyState.forwarderActive ? 'true' : 'false');
      return;
    }

    const notReadyState: CoreBridgeState = CoreBridgeService.markControllerReady(false, '');
    await this.stopTunnel();
    this.publishPhase('error');
    hilog.warn(DOMAIN, TAG, 'Controller readiness failed: message=%{public}s adapter=%{public}s adapterVersion=%{public}s nativeFd=%{public}d',
      controllerReady.message, notReadyState.adapterMode, notReadyState.adapterVersion, notReadyState.nativeFd);
  }

  private stopTunnel(): Promise<void> {
    if (!this.stopTask) {
      this.stopping = true;
      this.stopTask = this.finishStopTunnel();
    }
    return this.stopTask;
  }

  private async finishStopTunnel(): Promise<void> {
    const connection: vpnExtension.VpnConnection | undefined = this.connection;
    this.connection = undefined;
    this.tunFd = -1;
    this.publishPhase('stopping');
    // Queue Go shutdown, then release the system route immediately. Waiting for
    // the core first can leave the phone routed into a core that is stopping.
    const coreStop: Promise<CoreBridgeState> = CoreBridgeService.stopTun();
    let timer: number = -1;
    try {
      if (connection) {
        const timeout: Promise<void> = new Promise<void>((resolve, reject) => {
          timer = setTimeout(() => { reject(new Error('VPN connection destroy timed out')) }, 2500);
        });
        await Promise.race<void>([connection.destroy(), timeout]);
        hilog.info(DOMAIN, TAG, 'VPN connection destroyed');
      }
      this.publishPhase('disconnected');
    } catch (err) {
      this.publishPhase('error');
      hilog.warn(DOMAIN, TAG, 'Destroy VPN connection failed: %{public}s', JSON.stringify(err));
    } finally {
      clearTimeout(timer);
    }
    try {
      const coreState: CoreBridgeState = await coreStop;
      hilog.info(DOMAIN, TAG, 'Native core bridge stopped: mode=%{public}s nativeFd=%{public}d controllerReady=%{public}s stopCount=%{public}d',
        coreState.coreMode, coreState.nativeFd, coreState.controllerReady ? 'true' : 'false', coreState.stopCount);
      if (coreState.lastError.length > 0) {
        hilog.warn(DOMAIN, TAG, 'Native shutdown pending or failed: %{public}s', coreState.lastError);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Native shutdown failed: %{public}s', JSON.stringify(err));
    }
  }

  private createSafeTunConfig(): vpnExtension.VpnConfig {
    return {
      addresses: [
        {
          address: {
            address: '198.18.0.1',
            family: 1
          },
          prefixLength: 16
        }
      ],
      routes: [
        {
          interface: '',
          destination: {
            address: {
              address: '0.0.0.0',
              family: 1
            },
            prefixLength: 0
          },
          gateway: {
            address: '0.0.0.0',
            family: 1
          },
          hasGateway: false,
          isDefaultRoute: true
        }
      ],
      dnsAddresses: [
        '223.5.5.5',
        '119.29.29.29'
      ],
      mtu: 1500,
      isIPv4Accepted: true,
      isIPv6Accepted: false,
      isInternal: false,
      isBlocking: false
    };
  }
}
