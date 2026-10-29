import { Want } from '@kit.AbilityKit';
import { connection, vpnExtension } from '@kit.NetworkKit';
import nativeCore from 'libentry.so';
import { VpnControlChannel } from './VpnControlChannel';
import { VpnRuntimeEvents } from './VpnRuntimeEvents';
import { VpnBackgroundService } from './VpnBackgroundService';

const BUNDLE_NAME: string = 'io.github.clashharmony.app';
const VPN_ABILITY_NAME: string = 'ClashVpnExtensionAbility';
function createVpnWant(configPath?: string, sessionId: string = ''): Want {
  const want: Want = {
    bundleName: BUNDLE_NAME,
    abilityName: VPN_ABILITY_NAME
  };
  if (configPath && configPath.length > 0) {
    want.parameters = {
      configPath: configPath,
      sessionId: sessionId
    };
  }
  return want;
}

export class VpnService {
  private static previousGracefulStop: boolean = false;

  static async start(configPath: string, sessionId: string = ''): Promise<boolean> {
    // The route can be released while native cleanup is still in progress.
    // Explicitly retire that extension before a subsequent new session.
    if (VpnService.previousGracefulStop) {
      VpnService.previousGracefulStop = false;
      await VpnService.stop();
    }
    VpnBackgroundService.setEnabled(true);
    let timer: number = -1;
    try {
      const timeout: Promise<string> = new Promise<string>((resolve) => {
        timer = setTimeout(() => { resolve('timeout') }, 5000);
      });
      const result = await Promise.race([
        vpnExtension.startVpnExtensionAbility(createVpnWant(configPath, sessionId)),
        timeout
      ]);
      if (result === 'timeout') {
        VpnBackgroundService.setEnabled(false);
        return false;
      }
      return true;
    } catch (err) {
      VpnBackgroundService.setEnabled(false);
      return false;
    } finally {
      clearTimeout(timer);
    }
  }

  static async stopAndConfirm(sessionId: string, eventsAvailable: boolean): Promise<boolean> {
    if (!eventsAvailable || sessionId.length === 0) {
      const stopped: boolean = await VpnService.stop();
      if (stopped) { VpnBackgroundService.setEnabled(false) }
      return stopped;
    }
    // Register before sending so a fast route-release event cannot be missed.
    // Both waits start together: the SDK fallback shares the 3.2 second budget.
    const confirmation = VpnRuntimeEvents.waitFor(sessionId, ['disconnected', 'error'], 3200);
    const immediate = VpnRuntimeEvents.waitFor(sessionId, ['disconnected', 'error'], 800);
    VpnControlChannel.send('stop', sessionId);
    const first = await immediate;
    if (first?.phase !== 'disconnected') {
      const eventConfirmed: Promise<boolean> = confirmation.then((event) => event?.phase === 'disconnected');
      const systemConfirmed: Promise<boolean> = VpnService.stop(2400).then(async (stopped: boolean) => {
        if (stopped && await VpnService.hasSystemVpn() === false) { return true }
        return eventConfirmed;
      });
      if (!await Promise.race([eventConfirmed, systemConfirmed])) { return false }
    }
    VpnBackgroundService.setEnabled(false);
    VpnService.previousGracefulStop = true;
    return true;
  }

  static async hasSystemVpn(): Promise<boolean | undefined> {
    let timer: number = -1;
    try {
      const query: Promise<boolean> = (async (): Promise<boolean> => {
        const nets = await connection.getAllNets();
        const capabilities = await Promise.all(nets.map((net: connection.NetHandle) => connection.getNetCapabilities(net)));
        return capabilities.some((capability: connection.NetCapabilities) =>
          capability.bearerTypes.includes(connection.NetBearType.BEARER_VPN));
      })();
      const timeout: Promise<undefined> = new Promise<undefined>((resolve) => {
        timer = setTimeout(() => { resolve(undefined) }, 600);
      });
      return await Promise.race([query, timeout]);
    } catch (err) { return undefined }
    finally { clearTimeout(timer) }
  }

  static async stop(timeoutMs: number = 3000): Promise<boolean> {
    let timer: number = -1;
    try {
      const timeout: Promise<string> = new Promise<string>((resolve: (value: string) => void) => {
        timer = setTimeout(() => { resolve('timeout') }, timeoutMs);
      });
      const result: void | string = await Promise.race([
        vpnExtension.stopVpnExtensionAbility(createVpnWant()),
        timeout
      ]);
      if (result === 'timeout') {
        return false;
      }
      VpnBackgroundService.setEnabled(false);
      return true;
    } catch (err) {
      return false;
    } finally {
      clearTimeout(timer);
    }
  }

  static async protectSocket(fd: number): Promise<boolean> {
    try {
      nativeCore.protectSocket(fd);
      return true;
    } catch (err) {
      return false;
    }
  }
}
